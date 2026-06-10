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


// MARK: - Sidebar observation state models
struct SidebarStatusEntry: Equatable {
    let key: String
    let value: String
    let icon: String?
    let color: String?
    let url: URL?
    let priority: Int
    let format: SidebarMetadataFormat
    let timestamp: Date

    init(
        key: String,
        value: String,
        icon: String? = nil,
        color: String? = nil,
        url: URL? = nil,
        priority: Int = 0,
        format: SidebarMetadataFormat = .plain,
        timestamp: Date = Date()
    ) {
        self.key = key
        self.value = value
        self.icon = icon
        self.color = color
        self.url = url
        self.priority = priority
        self.format = format
        self.timestamp = timestamp
    }
}

struct SidebarMetadataBlock: Equatable {
    let key: String
    let markdown: String
    let priority: Int
    let timestamp: Date
}

enum SidebarMetadataFormat: String {
    case plain
    case markdown
}

enum SidebarLogLevel: String {
    case info
    case progress
    case success
    case warning
    case error
}

struct SidebarLogEntry: Equatable {
    let message: String
    let level: SidebarLogLevel
    let source: String?
    let timestamp: Date
}

struct SidebarProgressState: Equatable {
    let value: Double
    let label: String?
}

struct SidebarGitBranchState: Equatable {
    let branch: String
    let isDirty: Bool
}

struct SidebarPanelObservationState: Equatable {
    let panelIds: [UUID]

    init(panels: [UUID: any Panel]) {
        panelIds = panels.keys.sorted { $0.uuidString < $1.uuidString }
    }
}

enum SidebarPullRequestStatus: String {
    case open
    case merged
    case closed
}

func normalizedSidebarBranchName(_ branch: String?) -> String? {
    guard let branch else { return nil }
    let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

struct SidebarPullRequestState: Equatable {
    let number: Int
    let label: String
    let url: URL
    let status: SidebarPullRequestStatus
    let branch: String?
    let isStale: Bool

    init(
        number: Int,
        label: String,
        url: URL,
        status: SidebarPullRequestStatus,
        branch: String? = nil,
        isStale: Bool = false
    ) {
        self.number = number
        self.label = label
        self.url = url
        self.status = status
        self.branch = normalizedSidebarBranchName(branch)
        self.isStale = isStale
    }
}

