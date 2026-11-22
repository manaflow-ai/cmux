import AppKit
import Darwin
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// Measurement, not a gate (#32909 step B, lead: memory per chrome tree before landing): the process's
/// `phys_footprint` grows by this much for each browser chrome a pane holds, shown once in a window and laid
/// out, as a parked browser tab holds one today. Prints `CHROME-MEMORY per_chrome_kib=…`; asserts nothing
/// about the number.
@MainActor @Suite(.serialized, .closesItsWindows) struct BrowserChromeMemoryBench {
    static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1024 : 0
    }

    @Test func memoryPerChromeTree() {
        let count = 40
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSView(frame: window.contentLayoutRect)
        window.contentView = host
        // One first: shared caches (icon bitmaps, fonts, string tables) are paid once, not per chrome.
        func make() -> (BrowserChromeView, MockBrowserTab) {
            let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/")))
            tab.showsExtensionToolbar = true
            tab.load(URL(string: "https://example.com/")!)
            let chrome = BrowserChromeView(tab: tab)
            chrome.frame = host.bounds
            host.addSubview(chrome)
            chrome.layoutSubtreeIfNeeded()
            chrome.display()
            chrome.isHidden = true
            return (chrome, tab)
        }
        var kept = [make()]
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let before = Self.footprint()
        for _ in 0..<count { kept.append(make()) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let after = Self.footprint()
        let per = (after - before) / Double(count)
        print("CHROME-MEMORY per_chrome_kib=\(String(format: "%.1f", per)) chromes=\(count) before_kib=\(Int(before)) after_kib=\(Int(after))")
        #expect(before > 0)
        for (chrome, tab) in kept { BrowserPageRetirement(tab: tab, chrome: chrome).retire() }
    }
}
