import CmuxNextDaemon
import CmuxScreenKit
import Foundation

extension CmuxRemoteService {
    /// The attached app's capture in cmux Remote's Screen Sharing worker (docs/cmux-remote.md,
    /// "Attached capture"), and the grants that capture uses: cmux Remote's, read by its probe
    /// and asked for with `remote-host request`, so macOS prompts for and lists cmux Remote. A
    /// worker that does not serve both kinds (an older pinned cmux Remote) leaves both to the
    /// app's Screen Sharing helper or the app, as before.
    func attach(_ pages: MacScreenPages) {
        pages.hubHost.remoteCapture = MacScreenRemoteCapture(serves: { [weak self] in
            await self?.attachedCaptureKinds() ?? []
        }, open: { [weak self] in
            guard let self else { throw CmuxRemoteError.unavailable }
            return try await openChannel("screen-sharing").socket
        })
        pages.host.remoteGrants = MacScreenRemoteGrants(read: { [weak self] in
            await self?.attachedCaptureGrants()
        }, request: { [weak self] screenRecording in
            await self?.requestAttachedCaptureGrant(screenRecording: screenRecording) ?? false
        })
    }

    /// Both kinds of attached session the running worker serves, or none.
    func attachedCaptureKinds() async -> Set<String> {
        guard await waitAvailable(), let status = try? await status() else { return [] }
        return Self.attachedCaptureKinds(status["host"] ?? .null)
    }

    /// The kinds a host status's worker serves, when it serves them all (an older worker lists none).
    nonisolated static func attachedCaptureKinds(_ host: CmuxNextDaemon.JSONValue) -> Set<String> {
        let kinds = Set((host["screen"]?["serves"]?.arrayValue ?? []).compactMap(\.stringValue))
        return kinds.isSuperset(of: [AttachedScreenHost.rdKind, AttachedScreenHost.webRTCKind]) ? kinds : []
    }

    /// cmux Remote's own grants from a fresh probe (`refresh`), when its worker serves this app's capture.
    func attachedCaptureGrants() async -> MacScreenRemoteGrants.Read? {
        guard await waitAvailable(), let host = try? await call("refresh") else { return nil }
        return Self.attachedCaptureGrants(host)
    }

    nonisolated static func attachedCaptureGrants(_ host: CmuxNextDaemon.JSONValue) -> MacScreenRemoteGrants.Read? {
        guard !attachedCaptureKinds(host).isEmpty, let permissions = host["permissions"],
              let screen = permissions["screen_recording"]?.boolValue, let control = permissions["accessibility"]?.boolValue else {
            return nil
        }
        let name = host["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "cmux Remote"
        return MacScreenRemoteGrants.Read(screenRecording: screen, accessibility: control, name: name)
    }

    /// macOS's prompt for cmux Remote (it opens System Settings when macOS no longer prompts);
    /// false when its worker does not serve this app's capture, so the caller asks as before.
    func requestAttachedCaptureGrant(screenRecording: Bool) async -> Bool {
        let kinds = await attachedCaptureKinds()
        guard !kinds.isEmpty else { return false }
        let permission = screenRecording ? "screen-recording" : "accessibility"
        return (try? await call("request", .object(["permission": .string(permission)]))) != nil
    }
}

/// cmux Remote's grants for the attached app's capture (``MacScreenShareHost/remoteGrants``).
nonisolated struct MacScreenRemoteGrants: Sendable {
    struct Read: Sendable, Equatable {
        var screenRecording: Bool
        var accessibility: Bool
        /// The name System Settings lists them under.
        var name: String
    }

    /// cmux Remote's grants now; nil when it does not serve this app's capture.
    var read: @Sendable () async -> Read?
    /// macOS's prompt for cmux Remote; false when it does not serve this app's capture.
    var request: @Sendable (_ screenRecording: Bool) async -> Bool
}
