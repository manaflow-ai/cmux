import CmuxNextDesign
import CmuxNextSettings
import Testing

/// The markdown viewer's reading rows (Settings > Appearance > Markdown Viewer; the viewer's
/// Reading Settings popover writes the same keys): each has the page's default and range, refuses
/// values outside it, and an agent may set it (looks only).
struct MarkdownReadingSettingsTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let key: String
        let fallback: JSONValue
        let accepted: [JSONValue]
        let refused: [JSONValue]
        var testDescription: String { key }
    }

    static let rows: [Row] = [
        Row(key: "markdown.layout.width", fallback: .number(72), accepted: [.number(40), .number(100), .number(160)],
            refused: [.number(10), .number(500), .string("72ch")]),
        Row(key: "markdown.layout.fullWidth", fallback: .bool(false), accepted: [.bool(true)], refused: [.string("yes")]),
        Row(key: "markdown.font.preset", fallback: .string("system"), accepted: [.string("serif"), .string("mono")],
            refused: [.string("comic")]),
        Row(key: "markdown.font.lineHeight", fallback: .number(1.6), accepted: [.number(1), .number(2.4)],
            refused: [.number(0.5), .number(4)]),
        Row(key: "markdown.spacing.paragraph", fallback: .number(1), accepted: [.number(0), .number(3)],
            refused: [.number(-1), .number(5)]),
        Row(key: "markdown.code.blockSize", fallback: .number(14), accepted: [.number(8), .number(32)],
            refused: [.number(4), .number(64)]),
        Row(key: "markdown.tables", fallback: .string("scroll"), accepted: [.string("wrap")], refused: [.string("hide")]),
        Row(key: "markdown.theme", fallback: .string("app"), accepted: [.string("light"), .string("dark")],
            refused: [.string("sepia")]),
    ]

    @Test(arguments: rows)
    func eachRowHasThePageDefaultAndRange(_ row: Row) throws {
        let path = row.key.split(separator: ".").map(String.init)
        let descriptor = try #require(SettingsSchema.descriptor(for: path))
        #expect(descriptor.defaultValue == row.fallback)
        #expect(descriptor.effectiveValue(in: .object([:])) == row.fallback)
        for value in row.accepted { #expect(descriptor.accepts(value), "\(row.key) accepts \(value)") }
        for value in row.refused { #expect(!descriptor.accepts(value), "\(row.key) refuses \(value)") }
        #expect(SettingsSchema.agentSettableKeys.contains(row.key))
    }

    @Test func aStoredWidthIsTheEffectiveValue() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["markdown", "layout", "width"]))
        let root: JSONValue = .object(["markdown": .object(["layout": .object(["width": .number(96)])])])
        #expect(descriptor.effectiveValue(in: root) == .number(96))
        #expect(descriptor.isCustomized(in: root))
    }
}
