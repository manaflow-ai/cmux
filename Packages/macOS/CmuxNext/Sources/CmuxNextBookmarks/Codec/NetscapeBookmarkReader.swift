public import Foundation

/// A parsed Netscape bookmark file (the HTML every browser imports and
/// exports): the toolbar folder's children and everything else.
public nonisolated struct NetscapeBookmarkDocument: Sendable, Equatable {
    /// Children of the folder marked `PERSONAL_TOOLBAR_FOLDER="true"`, or nil
    /// when the file has none.
    public var bar: [BookmarkDraft]?
    /// Every other top-level node, in file order.
    public var other: [BookmarkDraft]

    public init(bar: [BookmarkDraft]?, other: [BookmarkDraft]) {
        self.bar = bar
        self.other = other
    }

    public var count: Int { (bar ?? []).reduce(0) { $0 + $1.count } + other.reduce(0) { $0 + $1.count } }

    /// The whole file as drafts for one "Imported" folder: the toolbar
    /// folder stays a subfolder named `barTitle`.
    public func drafts(barTitle: String) -> [BookmarkDraft] {
        guard let bar else { return other }
        return [BookmarkDraft.folder(barTitle, bar)] + other
    }
}

/// Reads the Netscape bookmark format (`<DL>`, `<DT><H3>`, `<DT><A HREF>`)
/// tolerantly: tags in any case, missing `</DT>` and `<p>`, unknown
/// attributes and stray text are fine; entries without a usable URL are
/// skipped.
public nonisolated enum NetscapeBookmarkReader {
    public static func read(_ html: String) -> NetscapeBookmarkDocument {
        var scanner = TagScanner(html)
        var stack: [[BookmarkDraft]] = [[]]
        var open: [OpenFolder] = []
        var queued: OpenFolder?
        var bar: [BookmarkDraft]?
        var sawRootList = false

        while let tag = scanner.nextTag() {
            switch tag.name {
            case "h3":
                let title = decode(scanner.text(until: "h3"))
                queued = OpenFolder(title: title, created: date(tag.attributes["add_date"]),
                                    toolbar: tag.attributes["personal_toolbar_folder"]?.lowercased() == "true", anonymous: false)
            case "a":
                let title = decode(scanner.text(until: "a"))
                guard let href = tag.attributes["href"].map(decode), let url = URL(string: href.trimmingCharacters(in: .whitespaces)),
                      url.scheme != nil else { continue }
                stack[stack.count - 1].append(.bookmark(title, url, created: date(tag.attributes["add_date"])))
            case "dl":
                if !sawRootList, queued == nil {
                    // The file's outer list is the root itself.
                    sawRootList = true
                    continue
                }
                sawRootList = true
                // A list with no heading keeps its items in the parent.
                open.append(queued ?? OpenFolder(title: "", created: nil, toolbar: false, anonymous: true))
                queued = nil
                stack.append([])
            case "/dl":
                guard stack.count > 1, let folder = open.popLast() else { continue }
                close(folder, children: stack.removeLast(), into: &stack, bar: &bar)
            default:
                continue
            }
        }
        // Unclosed lists at the end of a truncated file still count.
        while stack.count > 1, let folder = open.popLast() {
            close(folder, children: stack.removeLast(), into: &stack, bar: &bar)
        }
        if let folder = queued { stack[stack.count - 1].append(.folder(folder.title, created: folder.created, [])) }
        return NetscapeBookmarkDocument(bar: bar, other: stack[0])
    }

    private nonisolated struct OpenFolder {
        var title: String
        var created: Date?
        var toolbar: Bool
        var anonymous: Bool
    }

    private static func close(_ folder: OpenFolder, children: [BookmarkDraft], into stack: inout [[BookmarkDraft]],
                              bar: inout [BookmarkDraft]?) {
        if folder.toolbar, bar == nil, stack.count == 1 {
            bar = children
        } else if folder.anonymous {
            stack[stack.count - 1] += children
        } else {
            stack[stack.count - 1].append(.folder(folder.title, created: folder.created, children))
        }
    }

    static func date(_ value: String?) -> Date? {
        guard let value, let seconds = Double(value.trimmingCharacters(in: .whitespaces)), seconds > 0 else { return nil }
        // Some writers store microseconds (Chromium's internal format) or ms.
        if seconds > 1e14 { return Date(timeIntervalSince1970: seconds / 1_000_000) }
        if seconds > 1e11 { return Date(timeIntervalSince1970: seconds / 1000) }
        return Date(timeIntervalSince1970: seconds)
    }

    /// HTML character references: the five named ones and numeric forms.
    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "&", let semicolon = text[index...].prefix(12).firstIndex(of: ";") else {
                result.append(character)
                index = text.index(after: index)
                continue
            }
            let entity = text[text.index(after: index)..<semicolon].lowercased()
            if let scalar = entityScalar(entity) {
                result.unicodeScalars.append(scalar)
                index = text.index(after: semicolon)
            } else {
                result.append(character)
                index = text.index(after: index)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func entityScalar(_ entity: String) -> Unicode.Scalar? {
        switch entity {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return "\u{00A0}"
        default:
            if entity.hasPrefix("#x") { return UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init) }
            if entity.hasPrefix("#") { return UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init) }
            return nil
        }
    }
}
