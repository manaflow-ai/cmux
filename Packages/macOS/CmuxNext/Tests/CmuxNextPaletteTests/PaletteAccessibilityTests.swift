import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Testing

/// VoiceOver reads the command palette (cx-9ce.44): its panel exposes the query field, each visible
/// row as an element with its title, and which row is selected, so VoiceOver and an AX-driven test
/// find a row by title. Found by the cx-d0d.65 live check: the panel exposed no elements.
@MainActor
@Suite(.closesItsWindows)
struct PaletteAccessibilityTests {
    /// One node of the panel's accessibility tree, as an AX client reads it.
    private struct Node {
        var role: String
        var kind = ""
        var identifier: String
        var text: String
        var selected: Bool
        var children: [Node]

        var all: [Node] { [self] + children.flatMap(\.all) }
        /// Its own text and every descendant's, as VoiceOver reads an element.
        var spoken: String { ([text] + children.map(\.spoken)).filter { !$0.isEmpty }.joined(separator: ", ") }
    }

    /// `element`'s accessibility attribute, as an AX client reads it (AppKit's own row and cell
    /// elements are neither views nor `NSAccessibilityElement`s).
    private static func attribute(_ element: NSObject, _ name: NSAccessibility.Attribute) -> Any? {
        element.accessibilityAttributeValue(name)
    }

    private static func node(_ element: Any, depth: Int = 0) -> Node {
        guard let object = element as? NSObject else { return Node(role: "?", identifier: "", text: "", selected: false, children: []) }
        if object.accessibilityIsIgnored() {
            // An ignored element's children stand in its place.
            let children = (attribute(object, .children) as? [Any] ?? []).map { node($0, depth: depth + 1) }
            return Node(role: "", identifier: "", text: "", selected: false, children: children)
        }
        let texts = [NSAccessibility.Attribute.description, .title, .value].compactMap { attribute(object, $0) as? String }.filter { !$0.isEmpty }
        let text = texts.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let children = depth > 40 ? [] : (attribute(object, .children) as? [Any] ?? []).map { node($0, depth: depth + 1) }
        return Node(role: attribute(object, .role) as? String ?? "", kind: String(describing: type(of: object)),
                    identifier: attribute(object, .identifier) as? String ?? "",
                    text: text.joined(separator: ", "), selected: (attribute(object, .selected) as? Bool) ?? false, children: children)
    }

    private static func dump(_ node: Node, indent: String = "") -> String {
        "\(indent)\(node.role) <\(node.kind)> [\(node.identifier)] \(node.text)\(node.selected ? " (selected)" : "")\n"
            + node.children.map { dump($0, indent: indent + "  ") }.joined()
    }

    @Test func voiceOverReadsTheFieldTheRowsAndTheSelectedRow() async throws {
        _ = NSApplication.shared
        let palette = PaletteController(registry: .standard(), frecencyPersistence: nil)
        palette.show(.commands)
        defer { palette.closeForTest() }
        for _ in 0..<200 where palette.model.rows.count < 3 || palette.model.selectedItem == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let panel = try #require(palette.visiblePanel)
        panel.contentView?.layoutSubtreeIfNeeded()
        let selected = try #require(palette.model.selectedItem)
        let tree = Self.node(panel)
        let dump = Self.dump(tree)
        let nodes = tree.all

        // The query field, named for VoiceOver.
        let field = nodes.first { $0.identifier == "palette.search" }
        #expect(field != nil && field?.text.isEmpty == false, "no named query field:\n\(dump)")
        // Each visible row is an element that reads its title.
        let rows = nodes.filter { $0.role == NSAccessibility.Role.row.rawValue }
        let titles = palette.model.rows.prefix(3).map(\.item.title)
        for title in titles {
            #expect(rows.contains { $0.spoken.contains(title) }, "no row reads \(title):\n\(dump)")
        }
        // The selected row says so.
        let chosen = rows.filter(\.selected)
        #expect(chosen.count == 1 && chosen.first?.spoken.contains(selected.title) == true,
                "the selected row (\(selected.title)) is not the one selected element:\n\(dump)")
        // The table reports the same row as its selection, and follows the selection as it moves.
        let table = try #require(Self.first(PaletteTableView.self, in: panel.contentView))
        #expect(Self.reads(table, only: selected.title))
        palette.model.moveSelection(by: 1, wrap: false)
        let next = try #require(palette.model.selectedItem)
        #expect(next.title != selected.title)
        for _ in 0..<100 where !Self.reads(table, only: next.title) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(Self.reads(table, only: next.title))
    }

    private static func first<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let found = view as? T { return found }
        return view.subviews.lazy.compactMap { first(type, in: $0) }.first
    }

    /// Whether the table's selection, as VoiceOver asks for it, is one row that reads `title`.
    private static func reads(_ table: PaletteTableView, only title: String) -> Bool {
        let rows = (attribute(table, .selectedRows) as? [Any] ?? []).map { node($0).spoken }
        return rows.count == 1 && rows[0].contains(title)
    }
}
