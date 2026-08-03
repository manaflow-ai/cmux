//
//  TabsVisibleSidebarApp.swift
//  TabsVisibleSidebar
//
//  Created by Abdulaziz Albahar on 5/29/26.
//

import AppKit

@main
@MainActor
final class TabsVisibleSidebarApp: NSObject, NSApplicationDelegate {
    private var windowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentViewController: ContentViewController())
        window.title = String(localized: "tabsVisible.app.title", defaultValue: "Tabs Visible Sidebar")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.center()
        let controller = NSWindowController(window: window)
        windowController = controller
        controller.showWindow(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
