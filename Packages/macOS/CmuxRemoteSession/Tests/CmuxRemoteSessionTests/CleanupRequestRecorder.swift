import CmuxRemoteSession

@MainActor
final class CleanupRequestRecorder {
    var requests: [NativeSSHControlMasterCleanupRequest] = []
}
