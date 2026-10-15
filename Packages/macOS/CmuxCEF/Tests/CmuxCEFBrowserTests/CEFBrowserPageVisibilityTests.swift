import AppKit
import CmuxBrowser
import CmuxCEF
import Foundation
import Testing
@testable import CmuxCEFBrowser

@MainActor
@Suite("Chromium page visibility and hidden capture")
struct CEFBrowserPageVisibilityTests {
    /// A page whose host view sits in a window, as a pane's tab does.
    private func makePage() -> (CEFBrowserPage, NSWindow) {
        let page = CEFBrowserPage(browser: CEFBrowser(configuration: CEFBrowserConfiguration(profile: UUID())))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        page.contentView.frame = window.contentView!.bounds
        window.contentView!.addSubview(page.contentView)
        return (page, window)
    }

    @Test("A background tab hides its host view; showing it unhides it")
    func hidesBackgroundTab() {
        let (page, window) = makePage()
        page.setContentVisible(false)
        #expect(page.browser.hostView.isHidden)
        page.setContentVisible(true)
        #expect(!page.browser.hostView.isHidden)
        _ = window
    }

    @Test("A capture draws a hidden page covered, then hides it again; captures nest")
    func captureCoversAndRestores() async {
        let (page, window) = makePage()
        let host = page.browser.hostView
        page.setContentVisible(false)
        await page.withContentVisibleForCapture {
            #expect(!host.isHidden)
            #expect(host.isCoveredForCapture)
            #expect(host.cmuxOcclusionRects().count == 1)
            await page.withContentVisibleForCapture {
                #expect(!host.isHidden)
                #expect(host.isCoveredForCapture)
            }
            #expect(!host.isHidden)
            #expect(host.isCoveredForCapture)
        }
        #expect(host.isHidden)
        #expect(!host.isCoveredForCapture)
        _ = window
    }

    @Test("The pane showing the page during a capture wins: uncovered and visible after")
    func showDuringCapture() async {
        let (page, window) = makePage()
        let host = page.browser.hostView
        page.setContentVisible(false)
        await page.withContentVisibleForCapture {
            page.setContentVisible(true)
            #expect(!host.isCoveredForCapture)
            page.setContentVisible(false)
            #expect(host.isCoveredForCapture)
            page.setContentVisible(true)
        }
        #expect(!host.isHidden)
        #expect(!host.isCoveredForCapture)
        _ = window
    }

    @Test("A page on screen captures without being touched")
    func visiblePageUntouched() async {
        let (page, window) = makePage()
        let host = page.browser.hostView
        await page.withContentVisibleForCapture {
            #expect(!host.isCoveredForCapture)
        }
        #expect(!host.isHidden)
        _ = window
    }
}
