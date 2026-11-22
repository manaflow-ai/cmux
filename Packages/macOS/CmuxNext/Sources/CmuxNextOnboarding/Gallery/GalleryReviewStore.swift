public import Foundation

/// What the reviewer did in the gallery: where they are, the pick per
/// screen, a note per variant. Saved as JSON after every change, so position,
/// picks and notes survive a relaunch and the coordinator can read them.
public struct GalleryReview: Codable, Equatable, Sendable {
    /// Current screen (`OnboardingModel.Step` raw value) and variant index on it.
    public var step = OnboardingModel.Step.allCases[0].rawValue
    public var index = 0
    /// Picked variant id per step raw value.
    public var picks: [String: String] = [:]
    /// Note per variant id (empty notes are dropped).
    public var notes: [String: String] = [:]
    /// The variant pinned for Compare, per step.
    public var pinned: [String: String] = [:]
    public var darkPreview: Bool?

    public init() {}
}

/// Loads and saves a `GalleryReview` at one file URL.
@MainActor
public final class GalleryReviewStore {
    public let url: URL
    public private(set) var review: GalleryReview

    public init(url: URL) {
        self.url = url
        let data = FileManager.default.contents(atPath: url.path)
        review = data.flatMap { try? JSONDecoder().decode(GalleryReview.self, from: $0) } ?? GalleryReview()
    }

    public func update(_ change: (inout GalleryReview) -> Void) {
        change(&review)
        review.notes = review.notes.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var document = (try? JSONSerialization.jsonObject(with: encoder.encode(review))) as? [String: Any] ?? [:]
        document["summary"] = Self.summary(review)
        guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public func pick(for step: OnboardingModel.Step) -> String? { review.picks[step.rawValue] }

    /// "Default Browser: C (note: …) · Import: A · Theme: — (B: too dense)".
    public static func summary(_ review: GalleryReview) -> String {
        OnboardingModel.Step.allCases.map { step in
            let variants = step.variants
            var part = "\(step.galleryName): "
            if let id = review.picks[step.rawValue], let index = variants.firstIndex(where: { $0.id == id }) {
                part += index.galleryLetter
                if let note = review.notes[id] { part += " (note: \(note))" }
            } else {
                part += "—"
            }
            let others = variants.enumerated().compactMap { index, variant -> String? in
                guard variant.id != review.picks[step.rawValue], let note = review.notes[variant.id] else { return nil }
                return "\(index.galleryLetter): \(note)"
            }
            if !others.isEmpty { part += " [" + others.joined(separator: "; ") + "]" }
            return part
        }.joined(separator: " · ")
    }
}
