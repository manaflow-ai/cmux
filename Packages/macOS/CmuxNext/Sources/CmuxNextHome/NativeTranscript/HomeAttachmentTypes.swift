public import Foundation
public import CmuxHomeCore

/// One thing the user gave the composer: a file (drop, picker, a copied
/// file) or raw bytes with their type (a pasted screenshot).
nonisolated public enum HomeDraftInput: Hashable, Sendable {
    case file(URL)
    case data(Data, typeIdentifier: String)
}

/// Turns a draft input into a `LocalAttachment` (hash, blob cache copy,
/// display size, duration, poster). `HomeStore` is the implementation; the
/// composer only gathers inputs, and tests pass a recorder.
public protocol HomeAttachmentPreparing: AnyObject {
    /// `keepLocation` false strips GPS from photos (the default until the
    /// per-user setting lands).
    func prepareAttachment(fileURL: URL, keepLocation: Bool) async throws -> LocalAttachment
    func prepareAttachment(data: Data, typeIdentifier: String, keepLocation: Bool) async throws -> LocalAttachment
}

extension HomeStore: HomeAttachmentPreparing {}
