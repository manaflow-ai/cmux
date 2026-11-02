#if os(iOS)
import Observation
import SwiftUI
import UIKit

/// Sent images' thumbnails, decoded off the main thread once per image and size and kept for
/// every view that draws them. The live transcript decodes in its rows' `.task` and reads the
/// result here; a tab card's picture is drawn by a synchronous `ImageRenderer`, which never runs a
/// `.task`, so its key waits for `ready(_:)` and the drawn bubble reads the decoded image here.
///
/// The decoded pixels kept are bounded by bytes (least recently used first out, cost = pixel
/// bytes): a 4:3 image at
/// its 600 px short side is about 1.9 MB. Readiness only goes forward: a thumbnail once decoded,
/// or bytes that did not decode, stay ready after an eviction, so an eviction never starts a
/// decode that evicts another. A picture about to be drawn asks `resident(_:)`, which decodes
/// an evicted thumbnail again for that picture alone (`AgentCardRasterizer`).
@MainActor
@Observable
final class SentAttachmentThumbnails {
    static let shared = SentAttachmentThumbnails()

    /// Bumps when a thumbnail first becomes ready (decoded, or found undecodable). A second
    /// decode of an evicted one does not bump it: no card's readiness changed.
    private(set) var revision = 0
    /// Decoded thumbnails and their pixel bytes, least recently used first.
    @ObservationIgnored private var images: [String: (image: UIImage, cost: Int)] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var decoding: [String: Task<UIImage?, Never>] = [:]
    /// Keys decoded at least once, or whose bytes did not decode (`failed`), oldest first and
    /// bounded (a dropped key is only decoded once more).
    @ObservationIgnored private var settled: [String: Bool] = [:]
    @ObservationIgnored private var settledOrder: [String] = []
    static let settledLimit = 4096
    /// A bound on the decoded pixels kept.
    let byteLimit: Int
    /// Decodes started (tests).
    @ObservationIgnored private(set) var decodes = 0
    /// Bytes of the decoded thumbnails kept.
    @ObservationIgnored private(set) var residentBytes = 0

    init(byteLimit: Int = 32 << 20) {
        self.byteLimit = byteLimit
    }

    private func cached(_ key: String) -> UIImage? {
        guard let entry = images[key] else { return nil }
        if order.last != key, let index = order.lastIndex(of: key) {
            order.remove(at: index)
            order.append(key)
        }
        return entry.image
    }

    /// The point size a message's thumbnails are drawn at (`SentAttachments`): one image large,
    /// several as squares.
    nonisolated static func size(images: Int) -> CGSize {
        images == 1 ? CGSize(width: 200, height: 150) : CGSize(width: 96, height: 96)
    }

    /// Pixels on the short side a thumbnail is decoded at (3x its larger point side).
    nonisolated static func side(_ size: CGSize) -> CGFloat {
        max(size.width, size.height) * 3
    }

    /// A decoded image's pixel bytes.
    nonisolated static func cost(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return Int(image.size.width * image.scale * image.size.height * image.scale) * 4 }
        return cg.bytesPerRow * cg.height
    }

    private static func key(_ attachment: AgentAttachment, data: Data, side: CGFloat) -> String {
        "\(attachment.id)|\(data.count)|\(Int(side))"
    }

    /// The decoded thumbnail, if it is in memory. Not observed: a view that waits for it decodes it.
    func image(_ attachment: AgentAttachment, data: Data, side: CGFloat) -> UIImage? {
        cached(Self.key(attachment, data: data, side: side))
    }

    /// Decodes the thumbnail off the main thread (once per image and size at a time) and keeps it.
    func decode(_ attachment: AgentAttachment, data: Data, side: CGFloat) async -> UIImage? {
        await start(Self.key(attachment, data: data, side: side), data: data, side: side)?.value
    }

    /// The decode of `key`: the one running, or a new one; nil when it is in memory or its bytes
    /// did not decode (nothing to wait for).
    @discardableResult
    private func start(_ key: String, data: Data, side: CGFloat) -> Task<UIImage?, Never>? {
        if let image = cached(key) { return Task { image } }
        if settled[key] == false { return nil }
        if let running = decoding[key] { return running }
        decodes += 1
        let work = Task.detached(priority: .userInitiated) {
            UIImage(data: data).flatMap { $0.preparingThumbnail(of: SentAttachments.fill($0.size, side: side)) ?? $0 }
        }
        let task = Task { @MainActor [weak self] in
            let image = await work.value
            self?.landed(key, image)
            return image
        }
        decoding[key] = task
        return task
    }

    private func landed(_ key: String, _ image: UIImage?) {
        decoding[key] = nil
        if let image, images[key] == nil {
            let cost = Self.cost(image)
            images[key] = (image, cost)
            order.append(key)
            residentBytes += cost
            // The least recently used go past the bound (never the one just decoded).
            while residentBytes > byteLimit, order.count > 1 {
                let old = order.removeFirst()
                residentBytes -= images.removeValue(forKey: old)?.cost ?? 0
            }
        }
        guard settled[key] == nil else { return }
        settled[key] = image != nil
        settledOrder.append(key)
        while settledOrder.count > Self.settledLimit { settled[settledOrder.removeFirst()] = nil }
        revision &+= 1
    }

    /// The sent images of `turns` that have their bytes, at the size their bubbles draw them.
    private func wanted(_ turns: [AgentTurn]) -> [(key: String, data: Data, side: CGFloat)] {
        var out: [(String, Data, CGFloat)] = []
        for turn in turns {
            let images = turn.attachments.filter { $0.kind == .image }
            let side = Self.side(Self.size(images: images.count))
            for attachment in images.prefix(3) {
                guard let data = attachment.data else { continue }
                out.append((Self.key(attachment, data: data, side: side), data, side))
            }
        }
        return out
    }

    /// Whether every sent image of `turns` that has its bytes has been decoded at the size its
    /// bubble draws it (or found undecodable: the bubble draws its placeholder); starts decoding
    /// the ones never decoded. Observed: a caller re-reads it when one lands. Images without
    /// bytes (loaded from the Mac in a `.task`) are not counted here.
    func ready(_ turns: [AgentTurn]) -> Bool {
        _ = revision
        var ready = true
        for (key, data, side) in wanted(turns) where settled[key] == nil {
            ready = false
            start(key, data: data, side: side)
        }
        return ready
    }

    /// Whether every thumbnail `turns` draws is in memory now (or undecodable), to draw them into
    /// a picture; starts decoding again the ones evicted since. Not observed.
    func resident(_ turns: [AgentTurn]) -> Bool {
        var resident = true
        for (key, data, side) in wanted(turns) where settled[key] != false && cached(key) == nil {
            resident = false
            start(key, data: data, side: side)
        }
        return resident
    }
}
#endif
