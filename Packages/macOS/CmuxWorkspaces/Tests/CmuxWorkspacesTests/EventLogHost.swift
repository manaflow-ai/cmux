import Foundation
import os
@testable import CmuxWorkspaces

/// Appends host hook events to the same log the tracking `onChange` writes.
@MainActor
final class EventLogHost: WorkspacesHosting {
    typealias Tab = ObservedStubTab
    let log: OSAllocatedUnfairLock<[String]>

    init(log: OSAllocatedUnfairLock<[String]>) { self.log = log }
    func workspaceTabsWillChange(to newValue: [ObservedStubTab]) { log.withLock { $0.append("tabs.willSet") } }
    func workspaceGroupsWillChange(to newValue: [WorkspaceGroup]) { log.withLock { $0.append("groups.willSet") } }
    func selectedWorkspaceIdWillChange(to newValue: UUID?) { log.withLock { $0.append("selection.willSet") } }
    func selectedWorkspaceIdDidChange(from oldValue: UUID?) { log.withLock { $0.append("selection.didSet") } }
}
