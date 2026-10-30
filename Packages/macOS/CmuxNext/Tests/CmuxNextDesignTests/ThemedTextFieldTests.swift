import AppKit
import CmuxTheme
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// Theme sweep 3: a dialog's text field drew AppKit's bezel, text and gray placeholder whatever the
/// room's theme, and the editors' placeholders were macOS's `placeholderTextColor`. In a themed
/// scope a field's text is the scope's primary ink, its placeholder the scope's tertiary ink, and
/// a dialog field sits on the theme's field fill instead of the system bezel.
@MainActor @Suite(.serialized) struct ThemedTextFieldTests {
    /// A dark purple room theme: its inks are far from any system gray.
    private static func purpleScope() throws -> ThemeScope {
        let input = ThemeInput(background: ThemeRGB(hex: 0x2B1650), foreground: ThemeRGB(hex: 0xF4E3FF))
        let scope = ThemeScope(level: .room)
        scope.setOverride(try #require(ThemeSpec("Field Purple")), input: input, animated: false)
        return scope
    }

    /// A window whose content roots `scope`, with `view` installed in it.
    private static func host(_ view: NSView, in scope: ThemeScope) throws -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = try #require(window.contentView)
        scope.root(root)
        root.addSubview(view)
        return window
    }

    @Test func aDialogFieldDrawsTheThemeNotTheSystemBezel() throws {
        let scope = try Self.purpleScope()
        let spec = CmuxDialogSpec(title: "Rename Workspace", fields: [
            .text(id: "name", label: nil, initial: "", placeholder: "Workspace name", secure: false),
            .text(id: "token", label: nil, initial: "", placeholder: "Token", secure: true),
        ], buttons: [.ok("Save")])
        let dialog = CmuxDialogView(spec: spec)
        let window = try Self.host(dialog, in: scope)
        defer { window.close() }

        let ink = scope.perform { Palette.textPrimary }
        let hint = scope.perform { Palette.textTertiary }
        let lift = scope.perform { Palette.chromeBackground }
        for id in ["name", "token"] {
            let field = try #require(Self.find(dialog, id: "cmux.dialog.field.\(id)") as? NSTextField, "\(id)")
            #expect(!field.isBezeled && !field.drawsBackground, "\(id): AppKit's bezel and fill are gone")
            let text = try #require(field.textColor, "\(id)")
            #expect(Self.distance(text, ink) < 0.03, "\(id): text \(text) vs theme ink \(ink)")
            let placeholder = try #require(Self.placeholderInk(field), "\(id): the placeholder has a theme ink")
            #expect(Self.distance(placeholder, hint) < 0.03, "\(id): placeholder \(placeholder) vs theme hint \(hint)")
            let fill = try #require(field.superview?.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)),
                                    "\(id): the field sits on a theme fill")
            #expect(Self.distance(fill, lift) < 0.03, "\(id): fill \(fill) vs theme field fill \(lift)")
        }
    }

    /// The inline editors (group names, a server's approval code, an agent question's Other)
    /// share `ThemedTextField`: its placeholder is the scope's hint ink, not macOS's gray.
    @Test func aThemedFieldsPlaceholderIsTheScopesHintInk() throws {
        let scope = try Self.purpleScope()
        let field = ThemedTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        field.font = Typography.body
        field.placeholderString = "Group name"
        let window = try Self.host(field, in: scope)
        defer { window.close() }

        let hint = scope.perform { Palette.textTertiary }
        let placeholder = try #require(Self.placeholderInk(field), "the placeholder has a theme ink")
        #expect(Self.distance(placeholder, hint) < 0.03, "placeholder \(placeholder) vs theme hint \(hint)")
        #expect(field.placeholderString == "Group name")
    }

    private static func placeholderInk(_ field: NSTextField) -> NSColor? {
        guard let placeholder = field.placeholderAttributedString, placeholder.length > 0 else { return nil }
        return placeholder.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }

    private static func find(_ view: NSView, id: String) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        for subview in view.subviews {
            if let match = find(subview, id: id) { return match }
        }
        return nil
    }

    private static func distance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        guard let lhs = lhs.usingColorSpace(.sRGB), let rhs = rhs.usingColorSpace(.sRGB) else { return .infinity }
        return max(abs(lhs.redComponent - rhs.redComponent), abs(lhs.greenComponent - rhs.greenComponent),
                   abs(lhs.blueComponent - rhs.blueComponent))
    }
}
