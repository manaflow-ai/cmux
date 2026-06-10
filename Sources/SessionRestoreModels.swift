import Foundation
import SwiftUI
import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxSocketControl
import Combine
import CryptoKit
import Darwin
import Network
import CoreText


// MARK: - Session restore snapshot models
struct SessionPaneRestoreEntry {
    let paneId: PaneID
    let snapshot: SessionPaneLayoutSnapshot
}

struct ClosedBrowserPanelRestoreSnapshot {
    let workspaceId: UUID
    let url: URL?
    let profileID: UUID?
    let originalPaneId: UUID
    let originalTabIndex: Int
    let fallbackSplitOrientation: SplitOrientation?
    let fallbackSplitInsertFirst: Bool
    let fallbackAnchorPaneId: UUID?
    let closedAt: Date

    init(
        workspaceId: UUID,
        url: URL?,
        profileID: UUID?,
        originalPaneId: UUID,
        originalTabIndex: Int,
        fallbackSplitOrientation: SplitOrientation?,
        fallbackSplitInsertFirst: Bool,
        fallbackAnchorPaneId: UUID?,
        closedAt: Date = Date()
    ) {
        self.workspaceId = workspaceId
        self.url = url
        self.profileID = profileID
        self.originalPaneId = originalPaneId
        self.originalTabIndex = originalTabIndex
        self.fallbackSplitOrientation = fallbackSplitOrientation
        self.fallbackSplitInsertFirst = fallbackSplitInsertFirst
        self.fallbackAnchorPaneId = fallbackAnchorPaneId
        self.closedAt = closedAt
    }
}

