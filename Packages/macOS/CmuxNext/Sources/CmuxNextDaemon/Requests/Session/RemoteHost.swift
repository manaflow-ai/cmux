import Foundation

extension RemoteHostConfigRequest {
    /// This app's own Screen Recording and Accessibility: the grants that matter in a build
    /// without cmux Remote (Release and NIGHTLY), where the app captures the screen itself.
    public struct AppPermissions: Encodable, Sendable, Equatable {
        public var screenRecording: Bool?
        public var accessibility: Bool?

        public init(screenRecording: Bool?, accessibility: Bool?) {
            self.screenRecording = screenRecording
            self.accessibility = accessibility
        }
    }
}
