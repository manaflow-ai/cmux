public import CoreGraphics
public import Darwin
public import Foundation

/// The one process that holds this Mac's privacy grants for cmux NEXT: the Screen Sharing helper
/// (`<app>.app/Contents/Library/<app> Screen Sharing.app`, plans/cmux-next/screen-sharing-helper.md;
/// ``ScreenSharingHelperGrants``). The app never calls a TCC API itself (no Screen Recording,
/// Accessibility, Input Monitoring or PostEvent check, request or capture), so macOS never lists
/// "cmux NIGHTLY" in Privacy & Security and a grant never relaunches the app. A feature that needs
/// a grant asks the holder instead.
///
/// Leo, 2026-11-22: "who's gonna walk over and click allow on a headless mac mini, or a remote
/// macbook??? stop having that shit."
public nonisolated protocol GrantHolding: Sendable {
    /// Posts one key press (down, up) of virtual key `keyCode` with `flags` (only Command, Control,
    /// Option, Shift) at the HID level, so the app in front sees it as typed.
    func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) async -> GrantHolderAnswer
    /// One picture of the main display without `pid`'s windows, at most `maxWidth` pixels wide.
    func screenStill(maxWidth: Int, excluding pid: pid_t) async -> GrantHolderStill
    /// macOS's Accessibility prompt, naming the holder (shown at most once; after that the person
    /// turns it on in System Settings).
    func requestAccessibility() async
    /// macOS's Screen Recording prompt, naming the holder.
    func requestScreenRecording() async
}

/// What the holder said to a request.
public nonisolated enum GrantHolderAnswer: Sendable, Equatable {
    /// Done.
    case done
    /// The holder lacks the grant the request needs; nothing happened and nothing prompted.
    case notGranted
    /// This build has no holder, or it did not answer.
    case unavailable
}

/// A ``GrantHolding/screenStill(maxWidth:excluding:)`` answer.
public nonisolated enum GrantHolderStill: Sendable, Equatable {
    case pixels(GrantHolderPixels)
    case notGranted
    case unavailable
}

/// A still as the holder wrote it: tightly packed premultiplied RGBA8 sRGB, top row first.
public nonisolated struct GrantHolderPixels: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var rgba: Data

    public init(width: Int, height: Int, rgba: Data) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    /// The picture; nil when the bytes do not fill `width` x `height`.
    public var image: CGImage? {
        guard width > 0, height > 0, rgba.count == width * height * 4,
              let provider = CGDataProvider(data: rgba as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
