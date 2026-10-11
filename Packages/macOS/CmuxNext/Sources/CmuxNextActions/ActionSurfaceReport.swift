/// The generated part of plans/cmux-next/actions.md: catalog counts by category,
/// counts per surface, every menu's rows in order, and every exemption by
/// surface and reason.
/// `ActionSurfaceParityTests.reportIsFresh` keeps the file current, so a
/// menu reorder or a new exemption shows up in review.
public struct ActionSurfaceReport {
    public static let begin = "<!-- generated: action surfaces -->"
    public static let end = "<!-- /generated -->"

    /// The actions the report counts and lists exemptions for.
    public let descriptors: [ActionDescriptor]
    /// The menus whose rows the report lists.
    public let menus: ContextMenuCatalog

    /// A report over `descriptors` and `menus`.
    ///
    /// - Parameters:
    ///   - descriptors: The actions to count and list exemptions for.
    ///   - menus: The menus whose rows to list.
    public init(_ descriptors: [ActionDescriptor], menus: ContextMenuCatalog) {
        self.descriptors = descriptors
        self.menus = menus
    }

    /// The generated block, from ``begin`` to ``end``.
    public var markdown: String {
        let begin = Self.begin, end = Self.end
        var lines: [String] = [begin, ""]
        func offered(_ surface: ActionSurface) -> Int {
            descriptors.filter { $0.surfacePlan.decision(for: surface)?.isOffered == true }.count
        }
        lines.append("## Catalog counts")
        lines.append("")
        for category in ActionCategory.allCases where category != .other {
            let count = descriptors.filter { $0.category == category }.count
            lines.append("- `\(category.rawValue)`: \(count)")
        }
        lines.append("")
        lines.append("## Counts (\(descriptors.count) actions)")
        lines.append("")
        lines.append("Palette \(offered(.palette)), CLI verbs \(offered(.cli)), right-click \(offered(.contextMenu)), "
                     + "MCP tools \(offered(.mcp)).")
        lines.append("")
        lines.append("## Menus")
        lines.append("")
        for context in ActionMenuContext.allCases {
            lines.append("- **\(context.rawValue)**: " + Self.render(menus.entries(for: context)))
        }
        lines.append("")
        for surface in ActionSurface.allCases {
            lines.append("## Exemptions: \(surface.rawValue)")
            lines.append("")
            var byReason: [SurfaceExemption: [ActionID]] = [:]
            for descriptor in descriptors {
                guard let reason = descriptor.surfacePlan.decision(for: surface)?.exemption else { continue }
                // MCP repeats the CLI's reason for every action without a verb.
                if surface == .mcp, descriptor.surfacePlan.cli?.isOffered != true { continue }
                byReason[reason, default: []].append(descriptor.id)
            }
            for reason in SurfaceExemption.allCases {
                guard let ids = byReason[reason] else { continue }
                lines.append("**\(reason.rawValue)** (\(ids.count)): " + ids.map { "`\($0.rawValue)`" }.joined(separator: ", "))
                lines.append("")
            }
            if surface == .mcp { lines.append("Every action without a CLI verb is also no MCP tool, for the CLI's reason.\n") }
        }
        lines.append(end)
        return lines.joined(separator: "\n")
    }

    /// One menu on one line: `|` between sections, `>` opens a submenu.
    static func render(_ entries: [ContextMenuEntry]) -> String {
        entries.map { entry -> String in
            switch entry {
            case .separator: "|"
            case .action(let id): id.rawValue
            case .choices(let id): "\(id.rawValue)[choices]"
            case .submenu(let id, let children): "\(id.rawValue) > (" + render(children) + ")"
            case .folder(let folder, let children): "[\(folder.rawValue)] > (" + render(children) + ")"
            }
        }.joined(separator: " ")
    }
}
