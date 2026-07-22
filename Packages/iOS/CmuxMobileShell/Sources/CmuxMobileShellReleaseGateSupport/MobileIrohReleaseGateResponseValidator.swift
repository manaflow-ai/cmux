#if DEBUG
import CmuxAgentChat
import CmuxMobileRPC
import Foundation
internal import CmuxMobileShell

/// Pure response validation for the debug-only release gate.
///
/// The probe discards decoded values and publishes only operation booleans, so
/// chat descriptors, notification identifiers, session identifiers, and
/// artifact metadata never enter the report.
enum MobileIrohReleaseGateResponseValidator {
    static func independentEventSubscription(
        _ data: Data,
        expectedStreamID: String,
        expectedAlreadySubscribed: Bool? = nil
    ) -> Bool {
        guard let response = try? MobileEventSubscribeResponse.decode(data) else {
            return false
        }
        guard response.streamID == expectedStreamID,
              response.eventTransport == "iroh_server_events_v1" else {
            return false
        }
        return expectedAlreadySubscribed.map { response.alreadySubscribed == $0 } ?? true
    }

    static func independentEventUnsubscription(
        _ data: Data,
        expectedStreamID: String
    ) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["stream_id"] as? String == expectedStreamID
            && object["removed"] as? Bool == true
    }

    static func notificationReconcile(_ data: Data) -> Bool {
        guard let response = try? MobileNotificationReconcileResponse.decode(data) else {
            return false
        }
        return response.unreadCount.map { $0 >= 0 } ?? true
    }

    static func chatSessions(_ data: Data) -> Bool {
        (try? ChatWireCoding().decode(MobileChatSessionsResponse.self, from: data)) != nil
    }

    static func artifactScanCount(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let artifacts = object["artifacts"] as? [Any],
              artifacts.isEmpty,
              let response = try? JSONDecoder().decode(TerminalArtifactScanResponse.self, from: data) else {
            return false
        }
        return response.sessionArtifactTotal.map { $0 >= 0 } ?? true
    }

    static func artifactPath(
        _ data: Data,
        expectedPath: String
    ) -> Bool {
        guard let response = try? ChatWireCoding().decode(
            TerminalArtifactScanResponse.self,
            from: data
        ) else {
            return false
        }
        let expectedIdentity = releaseGateArtifactPathIdentity(expectedPath)
        return response.artifacts.contains {
            releaseGateArtifactPathIdentity($0.path) == expectedIdentity
        }
    }

    private static func releaseGateArtifactPathIdentity(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        let canonicalMacOSTemporaryPrefix = "/private/tmp/"
        guard standardized.hasPrefix(canonicalMacOSTemporaryPrefix) else {
            return standardized
        }
        return "/tmp/" + standardized.dropFirst(canonicalMacOSTemporaryPrefix.count)
    }

    static func artifactLaneDescriptor(_ data: Data) -> ChatArtifactLaneDescriptor? {
        try? ChatWireCoding().decode(ChatArtifactLaneDescriptor.self, from: data)
    }

    static func artifactStat(
        _ data: Data,
        expectedSize: Int64
    ) -> Bool {
        guard let stat = try? ChatWireCoding().decode(ChatArtifactStat.self, from: data) else {
            return false
        }
        return stat.exists && !stat.isDirectory && stat.size == expectedSize
    }
}
#endif
