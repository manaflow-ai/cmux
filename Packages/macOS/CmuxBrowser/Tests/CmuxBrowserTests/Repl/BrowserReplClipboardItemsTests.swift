import AppKit
import Testing
import UniformTypeIdentifiers

@testable import CmuxBrowser

/// A REPL tab's clipboard is filled by the agent (`clipboard.write`) and
/// then pasted into the page by WebKit's trusted Paste. A file reference
/// on that pasteboard (a file URL, a Finder filename list, an alias, a
/// file promise) would let WebKit hand a local file to the page as a
/// `File`, outside the session's file root, so none may reach it. Other
/// data, a web URL included, is pasted as given.
@MainActor
@Suite("Browser REPL clipboard items")
struct BrowserReplClipboardItemsTests {
    private static func item(_ type: String, _ text: String) -> [String: Any] {
        ["type": type, "base64": Data(text.utf8).base64EncodedString()]
    }

    private static let secret = URL(fileURLWithPath: "/etc/hosts")

    /// Every way a file reference can be spelled on a pasteboard, by MIME
    /// type or by raw pasteboard type.
    nonisolated static let fileReferences: [String] = [
        "public.file-url",
        "text/uri-list",
        "NSFilenamesPboardType",
        "com.apple.pasteboard.promised-file-url",
        "com.apple.pasteboard.promised-file-content-type",
        "NSPromiseContentsPboardType",
        "com.apple.NSFilePromiseItemMetaData",
        "Apple files promise pasteboard type",
        "com.apple.alias-file",
        "com.apple.finder.node",
        "Apple URL pasteboard type",
        "CorePasteboardFlavorType 0x6675726C",
        "WebURLsWithTitlesPboardType",
    ]

    @Test(arguments: fileReferences)
    func aFileReferenceNeverReachesThePasteboard(type: String) {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let path = Self.secret.path
        let value: String = switch type {
        case "NSFilenamesPboardType", "WebURLsWithTitlesPboardType":
            "<?xml version=\"1.0\"?><plist version=\"1.0\"><array><string>\(Self.secret.absoluteString)</string><string>\(path)</string></array></plist>"
        case "Apple files promise pasteboard type", "com.apple.pasteboard.promised-file-content-type", "NSPromiseContentsPboardType":
            "public.data"
        default:
            Self.secret.absoluteString
        }
        pasteboard.writeBrowserReplClipboardItems([Self.item("text/plain", "kept"), Self.item(type, value)])

        let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? []
        #expect(fileURLs.isEmpty, "a \(type) item put a file URL on the pasteboard WebKit pastes from")
        // Only the text item may be on the pasteboard, under any name
        // (a legacy type such as NSFilenamesPboardType is listed as a
        // dynamic type).
        let types = pasteboard.types ?? []
        #expect(types.contains(.string), "the item's text was dropped with the file reference")
        let onlyText = types.allSatisfy { $0 == .string || $0.rawValue == "NSStringPboardType" }
        #expect(onlyText, "a \(type) item reached the pasteboard WebKit pastes from")
    }

    @Test func aWebURLIsPastedAsGiven() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeBrowserReplClipboardItems([Self.item("text/uri-list", "https://example.com/a")])
        #expect(pasteboard.string(forType: .URL) == "https://example.com/a")
    }
}
