public import Foundation

/// A phone failure in plain words for people: what happened and what to do
/// next, never a tool's raw output. The raw text stays in ``detail`` (the
/// status line's tooltip, and what agents get from ``PhoneError/description``).
public struct PhoneErrorText: Sendable, Hashable, Error {
    /// One or two short sentences, localized: what went wrong and the next step.
    public var message: String
    /// The underlying error as the tool said it, for the tooltip and bug reports.
    public var detail: String

    public init(message: String, detail: String) {
        self.message = message
        self.detail = detail
    }

    /// The plain-words text for `error`.
    public init(_ error: any Error) {
        let detail = (error as? PhoneError)?.description ?? String(describing: error)
        if let text = error as? PhoneErrorText {
            self = text
            return
        }
        guard let phone = error as? PhoneError else {
            self.init(message: PhoneStrings.somethingWentWrong, detail: detail)
            return
        }
        self.init(message: Self.message(for: phone), detail: detail)
    }

    private static func message(for error: PhoneError) -> String {
        switch error {
        case .missingTool(.xcode): PhoneStrings.errorNeedsXcode
        case .missingTool(.androidSDK): PhoneStrings.errorNeedsAndroidStudio
        case .unknownDevice: PhoneStrings.errorUnknownPhone
        case .notRunning: PhoneStrings.errorNotRunning
        case .unsupported: PhoneStrings.errorUnsupported
        case .notRecording: PhoneStrings.errorNotRecording
        case .alreadyRecording: PhoneStrings.errorAlreadyRecording
        case .outsideScreen: PhoneStrings.errorOutsideScreen
        case .unreadable: PhoneStrings.errorUnreadable
        case .commandFailed(_, _, let stderr): message(forToolOutput: stderr)
        }
    }

    /// Known tool failures, matched on the words the tools print.
    private static func message(forToolOutput stderr: String) -> String {
        let text = stderr.lowercased()
        if text.contains("license") { return PhoneStrings.errorLicense }
        if text.contains("no space left") || text.contains("not enough space") || text.contains("insufficient space")
            || text.contains("disk is full") { return PhoneStrings.errorDiskFull }
        if text.contains("runtime") && (text.contains("unavailable") || text.contains("not available") || text.contains("cannot be located")) {
            return PhoneStrings.errorRuntimeMissing
        }
        if text.contains("unable to find utility") || text.contains("xcode-select") || text.contains("commandlinetools") {
            return PhoneStrings.errorNeedsXcode
        }
        if text.contains("nsurlerrordomain") || text.contains("network") || text.contains("offline") || text.contains("timed out") {
            return PhoneStrings.errorNetwork
        }
        return PhoneStrings.somethingWentWrong
    }
}
