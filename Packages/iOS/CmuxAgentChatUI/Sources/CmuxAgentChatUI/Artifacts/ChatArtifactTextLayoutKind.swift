import Foundation

/// Persistence buckets for artifact text layout choices.
enum ChatArtifactTextLayoutKind: String, Equatable, Sendable {
    case code
    case log
    case plainText

    init(path: String) {
        let pathExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        if pathExtension == "log" || pathExtension == "out" {
            self = .log
        } else if ChatArtifactSyntaxHighlightPolicy().inferredLanguage(path: path) != nil {
            self = .code
        } else {
            self = .plainText
        }
    }

    var defaultWrapsLines: Bool {
        self != .log
    }
}
