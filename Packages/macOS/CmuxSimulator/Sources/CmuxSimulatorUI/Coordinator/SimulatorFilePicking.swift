import Foundation

/// Native file-selection operations used by Simulator tools.
@MainActor
public protocol SimulatorFilePicking: AnyObject {
    /// Chooses an `.app` bundle or `.ipa` archive to install.
    func chooseApplication() async -> URL?
    /// Chooses photos, videos, contacts, or Live Photo resources to import.
    func chooseMedia() async -> [URL]
    /// Chooses an Apple Push Notification JSON payload.
    func choosePushPayload() async -> URL?
    /// Chooses an image or video source for experimental camera injection.
    func chooseCameraSource() async -> URL?
    /// Chooses where to save a Simulator screenshot.
    /// - Parameter fileExtension: The selected image format's extension.
    func chooseScreenshotDestination(fileExtension: String) async -> URL?
    /// Chooses where to save a Simulator video recording.
    func chooseVideoDestination() async -> URL?
}
