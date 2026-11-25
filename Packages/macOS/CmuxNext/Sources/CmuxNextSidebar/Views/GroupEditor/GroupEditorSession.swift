import AppKit
import CmuxNextDesign
import CmuxNextIcons
public import CmuxNextPages
import CmuxNextSettings

extension PageDescriptor {
    /// The sidebar's workspace group editor: cmux-page://cmux.group-editor/, built by
    /// scripts/cmux-next/build-pages-web.sh from webviews/src/pages/group-editor. The page owns no
    /// data: each open is a session the host pushes, and every edit goes back as a call.
    public static let groupEditor = PageDescriptor(id: "cmux.group-editor", resource: "group-editor", namespaces: ["cmux.groupEditor."],
                                            commands: [], acceptsFirstMouse: true)
}

/// What the group editor page shows for one open (`cmux.groupEditor.session`,
/// webviews/src/pages/group-editor/host.ts). Built on the main actor in the sidebar's theme, so the dots
/// are the colors the group's line draws.
@MainActor
struct GroupEditorSession {
    /// Echoed by every call, so a late call never edits a newer open's group.
    let id: String
    /// Bumped by every push; the page's ready names the revision it painted.
    var revision: Int
    var group: SidebarGroup
    var items: [[SidebarGroupEditorItem]]
    /// The name the person typed this open; nil while the field is untouched.
    var draft: String?

    /// The event the page gets; its dots draw in `palette`'s colors (`sidebar.groupPalette`).
    func event(palette: GroupPalette, icons: GroupEditorIcons) -> JSONValue {
        let dots: [JSONValue] = GroupColor.editorOrder.map { color in
            .object([
                "id": .string(color.rawValue),
                "label": .string(GroupEditorStrings.colorName(color)),
                "css": .string(Self.css(GroupTint.palette(color).lineRGB(palette: palette))),
                "chosen": .bool(group.tint == .palette(color) || (group.tint.isNone && color == .grey)),
                "outlined": .bool(color == .grey),
            ])
        }
        let custom: JSONValue = if case let .custom(rgb) = group.tint { .string(Self.css(rgb)) } else { .null }
        return .object([
            "id": .string(id),
            "revision": .number(Double(revision)),
            "name": .string(group.name),
            "draft": draft.map(JSONValue.string) ?? .null,
            "strings": .object([
                "editor": .string(GroupEditorStrings.editor),
                "nameLabel": .string(GroupEditorStrings.nameLabel),
                "namePlaceholder": .string(GroupEditorStrings.namePlaceholder),
                "customColor": .string(GroupEditorStrings.customColor),
                "emoji": .string(GroupEditorStrings.emoji),
            ]),
            "colors": .array(dots),
            "custom": .object(["css": custom, "chosen": .bool(custom != .null)]),
            "sections": .array(items.filter { !$0.isEmpty }.map { section in
                .array(section.map { item in
                    .object([
                        "id": .string(item.id),
                        "title": .string(item.title),
                        "icon": item.icon.flatMap(icons.dataURL).map(JSONValue.string) ?? .null,
                        "shortcut": item.shortcut.map(JSONValue.string) ?? .null,
                    ])
                })
            }),
        ])
    }

    /// `rgb` as a CSS color.
    static func css(_ rgb: ThemeRGB) -> String {
        let channel = { (value: Double) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return "rgba(\(channel(rgb.red)), \(channel(rgb.green)), \(channel(rgb.blue)), \(min(max(rgb.alpha, 0), 1)))"
    }
}

/// The editor rows' icons as black template PNGs in `data:` URLs (the page tints them with its theme's
/// secondary text color), drawn once per icon from the app's icon pack, so a row never waits on a load.
@MainActor
final class GroupEditorIcons {
    /// Points of the drawn icon; the page shows it at the row's icon size (2x for Retina).
    static let pointSize: CGFloat = 32
    private var drawn: [IconName: String] = [:]

    func dataURL(_ name: IconName) -> String? {
        if let url = drawn[name] { return url }
        let image = NSImage.icon(name, size: Self.pointSize)
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return nil }
        let url = "data:image/png;base64," + png.base64EncodedString()
        drawn[name] = url
        return url
    }
}
