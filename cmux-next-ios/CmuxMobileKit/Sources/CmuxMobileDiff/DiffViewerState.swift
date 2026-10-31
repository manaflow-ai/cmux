import CmuxMobileDesign
import Foundation
import Observation

/// Viewer preferences shared by the file list and file screens (SPEC 12.1 `ellipsis` menu).
@MainActor
@Observable
public final class DiffViewerState {
    public enum Layout: String, CaseIterable, Sendable { case unified = "Unified", split = "Split" }

    public var changeSet: DiffChangeSet
    public var layout: Layout = .unified
    /// Starts from Settings → Terminal → Wrap code and diff lines; the
    /// viewer's menu changes it for this screen.
    public var wrapLines = CmuxMobilePreferences.wrapCode()
    public var hideWhitespace = false
    public var showViewed = true
    /// The shared viewed marks (`DiffViewedStore`): the transcript, Changes, Review and
    /// the file screen all read and write the same model.
    public let viewedStore: DiffViewedStore

    public init(changeSet: DiffChangeSet, viewedStore: DiffViewedStore = .shared) {
        self.changeSet = changeSet
        self.viewedStore = viewedStore
    }

    /// Ids of this change set's files that are viewed.
    public var viewed: Set<String> { viewedStore.viewedIDs(in: changeSet) }

    public func isViewed(_ file: DiffFile) -> Bool { viewedStore.isViewed(file) }

    public func toggleViewed(_ file: DiffFile) {
        viewedStore.toggle(file)
    }
}
