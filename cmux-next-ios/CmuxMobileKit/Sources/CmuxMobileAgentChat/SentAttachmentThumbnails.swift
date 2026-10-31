#if os(iOS)
import Observation
import SwiftUI
import UIKit

/// Sent images' thumbnails, decoded off the main thread once per image and size and kept for
/// every view that draws them. The live transcript decodes in its rows' `.task` and reads the
/// result here; a tab card's picture is drawn by a synchronous `ImageRenderer`, which never runs a
/// `.task`, so its key waits for `ready(_:)` and the drawn bubble reads the decoded image here.
@MainActor
@Observable
final class SentAttachmentThumbnails {
    static let shared = SentAttachmentThumbnails()

    /// Bumps when a thumbnail lands (a card waiting for one is keyed on it).
    private(set) var revision = 0
    @ObservationIgnored private var images: [String: UIImage] = [:]
    /// Oldest first; past `limit` the oldest goes.
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var decoding: [String: Task<UIImage?, Never>] = [:]
    /// About 1 MB each at the largest size: a long chat's images and a grid's cards.
    let limit: Int

    init(limit: Int = 96) {
        self.limit = limit
    }

    /// The point side a message's thumbnails are drawn at (`SentAttachments`): one image large,
    /// several as squares.
    nonisolated static func size(images: Int) -> CGSize {
        images == 1 ? CGSize(width: 200, height: 150) : CGSize(width: 96, height: 96)
    }

    /// Pixels on the short side a thumbnail is decoded at (3x its larger point side).
    nonisolated static func side(_ size: CGSize) -> CGFloat {
        max(size.width, size.height) * 3
    }

    private static func key(_ attachment: AgentAttachment, data: Data, side: CGFloat) -> String {
        "\(attachment.id)|\(data.count)|\(Int(side))"
    }

    /// The decoded thumbnail, if it is ready. Not observed: a view that waits for it decodes it.
    func image(_ attachment: AgentAttachment, data: Data, side: CGFloat) -> UIImage? {
        images[Self.key(attachment, data: data, side: side)]
    }

    /// Decodes the thumbnail off the main thread (once per image and size) and keeps it.
    func decode(_ attachment: AgentAttachment, data: Data, side: CGFloat) async -> UIImage? {
        let key = Self.key(attachment, data: data, side: side)
        if let image = images[key] { return image }
        if let running = decoding[key] { return await running.value }
        let work = Task.detached(priority: .userInitiated) {
            UIImage(data: data).flatMap { $0.preparingThumbnail(of: SentAttachments.fill($0.size, side: side)) ?? $0 }
        }
        let task = Task { @MainActor [weak self] in
            let image = await work.value
            self?.landed(key, image)
            return image
        }
        decoding[key] = task
        return await task.value
    }

    private func landed(_ key: String, _ image: UIImage?) {
        decoding[key] = nil
        guard let image else { return }
        images[key] = image
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > limit { images[order.removeFirst()] = nil }
        revision &+= 1
    }

    /// Whether every sent image of `turns` that has its bytes is decoded at the size its bubble
    /// draws it; starts decoding the ones that are not. Observed: a caller re-reads it when one
    /// lands. Images without bytes (loaded from the Mac in a `.task`) are not counted here.
    func ready(_ turns: [AgentTurn]) -> Bool {
        _ = revision
        var ready = true
        for turn in turns {
            let images = turn.attachments.filter { $0.kind == .image }
            let side = Self.side(Self.size(images: images.count))
            for attachment in images.prefix(3) {
                guard let data = attachment.data, image(attachment, data: data, side: side) == nil else { continue }
                ready = false
                Task { @MainActor [weak self] in _ = await self?.decode(attachment, data: data, side: side) }
            }
        }
        return ready
    }
}
#endif
