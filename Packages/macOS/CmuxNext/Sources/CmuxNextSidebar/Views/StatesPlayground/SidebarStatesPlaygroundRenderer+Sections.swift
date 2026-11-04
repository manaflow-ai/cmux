import AppKit
import CmuxNextDesign

extension SidebarStatesPlaygroundRenderer {
    /// The room a look's views get: wide and tall enough for a Home list's header and its empty list.
    static let lookRoom = NSSize(width: 480, height: 720)

    /// Every look of `section` drawn at `column` in `appearance`, in order: each look staged alone in its own
    /// offscreen window, in the sheet's theme, while the column's `sidebar.density` and `sidebar.textSize` are set.
    func lookCells(_ section: SidebarStatesPlaygroundSection, _ column: SidebarStatesPlaygroundColumn,
                   _ appearance: SidebarStatesPlaygroundAppearance) -> [SidebarStatesPlaygroundLookCell] {
        let saved = design.sidebarSections
        design.sidebarSections.density = column.density
        design.sidebarSections.textSize = column.textSize
        defer { design.sidebarSections = saved }
        return section.looks.map { lookCell($0, appearance) }
    }

    private func lookCell(_ look: SidebarStatesPlaygroundLook, _ appearance: SidebarStatesPlaygroundAppearance) -> SidebarStatesPlaygroundLookCell {
        let room = NSRect(origin: .zero, size: Self.lookRoom)
        let window = NSWindow(contentRect: room.offsetBy(dx: -40_000, dy: -40_000), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.ignoresMouseEvents = true
        window.alphaValue = 0 // drawn into a bitmap only; never seen
        window.appearance = appearance.appearance
        defer {
            window.orderOut(nil)
            window.close()
        }
        let root = NSView(frame: room)
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        let scope = ThemeScope(level: .room)
        if let theme = themes.theme(appearance) { scope.setOverride(theme.spec, input: theme.input, animated: false) }
        scope.root(root)
        // glass-opaque-allow: the stand-in for the window behind the views in an offscreen shot (no desktop shows through), not a glass surface.
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        window.orderFrontRegardless()
        let shown = look.stage(root).intersection(root.bounds)
        root.layoutSubtreeIfNeeded()
        guard !shown.isEmpty, let shot = Self.draw(root, pixelScale: pixelScale) else {
            return SidebarStatesPlaygroundLookCell(image: nil, size: shown.size)
        }
        let scale = CGFloat(shot.width) / root.bounds.width
        let pixels = CGRect(x: shown.minX * scale, y: (root.bounds.height - shown.maxY) * scale, width: shown.width * scale,
                            height: shown.height * scale).integral
        return SidebarStatesPlaygroundLookCell(image: shot.cropping(to: pixels), size: shown.size)
    }
}
