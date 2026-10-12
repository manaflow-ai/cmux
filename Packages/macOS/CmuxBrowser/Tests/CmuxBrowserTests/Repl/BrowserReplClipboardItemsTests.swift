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

    private static func item(_ type: String, data: Data) -> [String: Any] {
        ["type": type, "base64": data.base64EncodedString()]
    }

    /// A denylist of names and a UTF-8 `file:` scan misses encodings a page
    /// or agent can choose: a URL type holding UTF-16, a filename list as a
    /// binary property list, a raw type name, RTFD with attachments. Only
    /// the types the virtual clipboard needs may reach the pasteboard.
    nonisolated static let evasive: [(type: String, data: Data)] = {
        let fileURL = URL(fileURLWithPath: "/etc/hosts").absoluteString
        let binaryList = (try? PropertyListSerialization.data(fromPropertyList: ["/etc/hosts"], format: .binary, options: 0)) ?? Data()
        return [
            ("public.url", fileURL.data(using: .utf16LittleEndian)!),
            ("public.url", fileURL.data(using: .utf16)!),
            ("Apple URL pasteboard type", binaryList),
            ("NSFilenamesPboardType", binaryList),
            ("com.apple.flat-rtfd", Data("rtfd".utf8)),
            ("com.apple.webarchive", Data("archive".utf8)),
            ("public.utf8-plain-text-but-not", Data("x".utf8)),
            ("dyn.ah62d4rv4gu8yc6durvwwaznwmuuha2pxsvw0e55bsmwca7d3sbwu", Data(fileURL.utf8)),
            ("text/uri-list", Data("javascript:alert(1)".utf8)),
            ("text/uri-list", Data("https://example.com/a\nfile:///etc/hosts".utf8)),
            ("text/uri-list", Data("data:text/html,x".utf8)),
        ]
    }()

    @Test(arguments: evasive.indices)
    func onlyAllowedTypesReachThePasteboard(index: Int) {
        let entry = Self.evasive[index]
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeBrowserReplClipboardItems([Self.item("text/plain", "kept"), Self.item(entry.type, data: entry.data)])
        let types = pasteboard.types ?? []
        #expect(types.contains(.string), "the item's text was dropped with the \(entry.type) item")
        let onlyText = types.allSatisfy { $0 == .string || $0.rawValue == "NSStringPboardType" }
        #expect(onlyText, "a \(entry.type) item (case \(index)) reached the pasteboard WebKit pastes from: \(types.map(\.rawValue))")
    }

    /// What the virtual clipboard needs still reaches it: text, HTML, RTF,
    /// PNG, TIFF, WebKit's custom web data and an http(s) URL.
    @Test func theTypesTheTabClipboardNeedsArePasted() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeBrowserReplClipboardItems([
            Self.item("text/plain", "text"),
            Self.item("text/html", "<b>html</b>"),
            Self.item("text/rtf", "{\\rtf1 rtf}"),
            Self.item("image/png", "png"),
            Self.item("image/tiff", "tiff"),
            Self.item("com.apple.WebKit.custom-pasteboard-data", "custom"),
            Self.item("text/uri-list", "http://example.com/b"),
        ])
        let types = Set(pasteboard.types ?? [])
        for expected: NSPasteboard.PasteboardType in [.string, .html, .rtf, .png, .tiff, .URL, NSPasteboard.PasteboardType("com.apple.WebKit.custom-pasteboard-data")] {
            #expect(types.contains(expected), "\(expected.rawValue) was dropped")
        }
    }
}

