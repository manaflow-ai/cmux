import AppKit

/// Accessibility of markdown messages (shared/MARKDOWN.md): a message with markdown
/// becomes a group whose children follow the document: paragraphs (static text),
/// headings (AXHeading with the level as value), lists and items (task items are
/// read-only checkboxes), quotes, code blocks (the exact code as value), tables
/// (AXTable with AXRow and AXCell children, row and column counts and index
/// ranges) and links (AXLink with the URL). Frames are the drawn frames on screen.
enum MarkdownAccess {
    static func decorate(_ e: NSAccessibilityElement, _ c: ChatController, id: ID) {
        guard let demo = c.demo, let window = c.host.window else { return }
        var kids: [NSAccessibilityElement] = []
        for case let cell as RowCell in demo.collection.visibleCells where !cell.isHidden {
            guard let spec = cell.spec, case let .part(p) = spec.kind, p.ref.messageId == id, let md = p.markdown else { continue }
            let body = cell.convert(RowDraw.bodyRect(spec), to: demo)
            let toScreen: (CGRect) -> CGRect = { r in
                window.convertToScreen(c.host.convert(r.offsetBy(dx: body.minX, dy: body.minY), to: nil))
            }
            for n in md.ax { kids.append(element(n, md, parent: e, toScreen)) }
        }
        guard !kids.isEmpty else { return }
        // The message keeps its role (its selected-text attributes stay); the structure is its children.
        e.setAccessibilityChildren(kids)
    }

    static func element(_ n: MDAXNode, _ md: MarkdownLayout, parent: Any, _ toScreen: (CGRect) -> CGRect) -> NSAccessibilityElement {
        let e = NSAccessibilityElement()
        e.setAccessibilityParent(parent)
        e.setAccessibilityFrame(toScreen(n.frame))
        let text = md.substring(n.range)
        func children() { e.setAccessibilityChildren(n.children.map { element($0, md, parent: e, toScreen) }) }
        switch n.kind {
        case .paragraph:
            e.setAccessibilityRole(.staticText)
            e.setAccessibilityValue(text)
            links(e, n, md, toScreen)
        case let .heading(level):
            e.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
            e.setAccessibilityValue(String(level))
            e.setAccessibilityTitle(text)
            e.setAccessibilityLabel(text)
            e.setAccessibilityRoleDescription(String(format: MessagesLabLocalization.string("markdown.ax.heading", "Heading level %d"), level))
        case let .list(ordered):
            e.setAccessibilityRole(.list)
            e.setAccessibilitySubrole(ordered ? NSAccessibility.Subrole(rawValue: "AXContentList") : nil)
            e.setAccessibilityLabel(String(format: MessagesLabLocalization.string("markdown.ax.list", "List, %d items"), n.children.count))
            children()
        case .item:
            // A task item's display text starts with its box ("☐ " / "☑ ").
            if text.hasPrefix("☐ ") || text.hasPrefix("☑ ") {
                e.setAccessibilityRole(.checkBox)
                e.setAccessibilityValue(text.hasPrefix("☑ ") ? 1 : 0)
                e.setAccessibilityEnabled(false)
                e.setAccessibilityLabel(String(text.dropFirst(2)))
            } else {
                e.setAccessibilityRole(.group)
                e.setAccessibilityRoleDescription(NSAccessibility.Role.group.description(with: nil))
                e.setAccessibilityLabel(text)
            }
            children()
        case .quote:
            e.setAccessibilityRole(.group)
            e.setAccessibilityRoleDescription(MessagesLabLocalization.string("markdown.ax.quote", "Quote"))
            children()
        case let .code(lang):
            e.setAccessibilityRole(.textArea)
            e.setAccessibilityValue(text)
            e.setAccessibilityEnabled(false)
            e.setAccessibilityLabel(String(format: MessagesLabLocalization.string("markdown.ax.codeBlock", "Code block, %@"), lang.isEmpty ? MessagesLabLocalization.string("markdown.ax.codeText", "text") : lang))
        case let .table(rows, cols):
            e.setAccessibilityRole(.table)
            e.setAccessibilityRowCount(rows)
            e.setAccessibilityColumnCount(cols)
            e.setAccessibilityLabel(String(format: MessagesLabLocalization.string("markdown.ax.table", "Table, %1$d rows, %2$d columns"), rows, cols))
            var rowEls: [NSAccessibilityElement] = []
            for (ri, row) in n.children.enumerated() {
                let r = NSAccessibilityElement()
                r.setAccessibilityRole(.row)
                r.setAccessibilityParent(e)
                r.setAccessibilityIndex(ri)
                r.setAccessibilityFrame(toScreen(row.frame))
                var cells: [NSAccessibilityElement] = []
                for (ci, cn) in row.children.enumerated() {
                    let c = NSAccessibilityElement()
                    c.setAccessibilityRole(.cell)
                    c.setAccessibilityParent(r)
                    c.setAccessibilityRowIndexRange(NSRange(location: ri, length: 1))
                    c.setAccessibilityColumnIndexRange(NSRange(location: ci, length: 1))
                    c.setAccessibilityValue(md.substring(cn.range))
                    c.setAccessibilityFrame(toScreen(cn.frame))
                    cells.append(c)
                }
                r.setAccessibilityChildren(cells)
                rowEls.append(r)
            }
            e.setAccessibilityChildren(rowEls)
            e.setAccessibilityRows(rowEls)
            if let head = rowEls.first { e.setAccessibilityColumnHeaderUIElements(head.accessibilityChildren() ?? []) }
        case .rule:
            e.setAccessibilityRole(.splitter)
        case .row, .cell, .link:
            e.setAccessibilityRole(.staticText)
            e.setAccessibilityValue(text)
        }
        return e
    }

    /// Links inside a paragraph as AXLink children (URL as value).
    static func links(_ e: NSAccessibilityElement, _ n: MDAXNode, _ md: MarkdownLayout, _ toScreen: (CGRect) -> CGRect) {
        var out: [NSAccessibilityElement] = []
        for f in md.frags where NSIntersectionRange(f.range, n.range).length > 0 {
            for (r, url) in f.links {
                let l = NSAccessibilityElement()
                l.setAccessibilityRole(.link)
                l.setAccessibilityParent(e)
                l.setAccessibilityTitle((f.attr.string as NSString).substring(with: r))
                l.setAccessibilityURL(URL(string: url))
                l.setAccessibilityValue(url)
                let x0 = CTLineGetOffsetForStringIndex(f.line, r.location, nil), x1 = CTLineGetOffsetForStringIndex(f.line, NSMaxRange(r), nil)
                l.setAccessibilityFrame(toScreen(CGRect(x: f.origin.x + x0, y: f.origin.y, width: x1 - x0, height: f.height)))
                out.append(l)
            }
        }
        if !out.isEmpty { e.setAccessibilityChildren(out) }
    }
}
