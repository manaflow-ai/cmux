// Sources/Island/NotchPanel.swift
//
// Mechanics adapted from https://github.com/farouqaldori/claude-island
//   ClaudeIsland/UI/Window/NotchWindow.swift
// License: Apache 2.0. See THIRD_PARTY_LICENSES.md.

import AppKit

/// `NSPanel` subclass used as the host window for the cmux Island overlay.
///
/// Behaves as a non-activating, always-on-top floating panel that joins
/// every Space and sits above the menu bar. When collapsed, the panel
/// ignores mouse events so clicks pass through to the menu bar and apps
/// underneath; when expanded, the `IslandWindowController` flips
/// `ignoresMouseEvents` off so the row buttons are clickable.
final class NotchPanel: NSPanel {

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        hasShadow = false
        isMovable = false

        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle
        ]

        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)

        allowsToolTipsWhenApplicationIsInactive = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = true
        acceptsMouseMovedEvents = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
