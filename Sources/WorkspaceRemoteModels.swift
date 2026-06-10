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


// MARK: - Remote connection model types
enum RemoteDropUploadError: LocalizedError {
    case unavailable
    case invalidFileURL
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(
                localized: "error.remoteDrop.unavailable",
                defaultValue: "Remote drop is unavailable."
            )
        case .invalidFileURL:
            String(
                localized: "error.remoteDrop.invalidFileURL",
                defaultValue: "Dropped item is not a file URL."
            )
        case .uploadFailed(let detail):
            String.localizedStringWithFormat(
                String(
                    localized: "error.remoteDrop.uploadFailed",
                    defaultValue: "Failed to upload dropped file: %@"
                ),
                detail
            )
        }
    }
}

struct WorkspaceRemoteDaemonManifest: Decodable, Equatable {
    struct Entry: Decodable, Equatable {
        let goOS: String
        let goArch: String
        let assetName: String
        let downloadURL: String
        let sha256: String
    }

    let schemaVersion: Int
    let appVersion: String
    let releaseTag: String
    let releaseURL: String
    let checksumsAssetName: String
    let checksumsURL: String
    let entries: [Entry]

    func entry(goOS: String, goArch: String) -> Entry? {
        entries.first { $0.goOS == goOS && $0.goArch == goArch }
    }
}

enum WorkspaceRemoteConnectionState: String {
    case disconnected
    case connecting
    case reconnecting
    case connected
    case error
}

enum WorkspaceRemoteDaemonState: String {
    case unavailable
    case bootstrapping
    case ready
    case error
}

struct WorkspaceRemoteDaemonStatus: Equatable {
    var state: WorkspaceRemoteDaemonState = .unavailable
    var detail: String?
    var version: String?
    var name: String?
    var capabilities: [String] = []
    var remotePath: String?

    func payload() -> [String: Any] {
        [
            "state": state.rawValue,
            "detail": detail ?? NSNull(),
            "version": version ?? NSNull(),
            "name": name ?? NSNull(),
            "capabilities": capabilities,
            "remote_path": remotePath ?? NSNull(),
        ]
    }
}

