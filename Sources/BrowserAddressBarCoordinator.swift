import AppKit
import Foundation
#if DEBUG
import Bonsplit
#endif

@MainActor
@Observable
final class BrowserAddressBarCoordinator {
    typealias PanelLookup = @MainActor (UUID) -> BrowserPanel?
    typealias PanelOwnerLookup = @MainActor (CmuxWebView) -> BrowserPanel?
    typealias ShouldPreserveCheck = @MainActor (BrowserPanel) -> Bool

    private(set) var focusedPanelId: UUID?

    @ObservationIgnored private var repeatStartWorkItem: DispatchWorkItem?
    @ObservationIgnored private var repeatTickWorkItem: DispatchWorkItem?
    @ObservationIgnored private var repeatKeyCode: UInt16?
    @ObservationIgnored private var repeatDelta: Int = 0

    @ObservationIgnored private var focusObserver: NSObjectProtocol?
    @ObservationIgnored private var blurObserver: NSObjectProtocol?
    @ObservationIgnored private var webViewFirstResponderObserver: NSObjectProtocol?

    @ObservationIgnored private let panelLookup: PanelLookup
    @ObservationIgnored private let panelOwnerLookup: PanelOwnerLookup
    @ObservationIgnored private let shouldPreserveCheck: ShouldPreserveCheck

    init(
        panelLookup: @escaping PanelLookup,
        panelOwnerLookup: @escaping PanelOwnerLookup,
        shouldPreserveCheck: @escaping ShouldPreserveCheck
    ) {
        self.panelLookup = panelLookup
        self.panelOwnerLookup = panelOwnerLookup
        self.shouldPreserveCheck = shouldPreserveCheck
    }

    deinit {
        if let focusObserver {
            NotificationCenter.default.removeObserver(focusObserver)
        }
        if let blurObserver {
            NotificationCenter.default.removeObserver(blurObserver)
        }
        if let webViewFirstResponderObserver {
            NotificationCenter.default.removeObserver(webViewFirstResponderObserver)
        }
    }

    // MARK: Public state mutation

    func setFocusedPanel(_ panelId: UUID) {
        focusedPanelId = panelId
    }

    func clearFocusIfMatches(_ panelId: UUID) {
        guard focusedPanelId == panelId else { return }
        focusedPanelId = nil
        stopOmnibarSelectionRepeat()
    }

    func clearFocus() {
        focusedPanelId = nil
        stopOmnibarSelectionRepeat()
    }

    // MARK: Omnibar selection repeat

    func dispatchOmnibarSelectionMove(delta: Int) {
        guard delta != 0 else { return }
        guard let panelId = focusedPanelId else { return }
        #if DEBUG
        dlog(
            "browser.focus.omnibar.selectionMove panel=\(panelId.uuidString.prefix(5)) " +
            "delta=\(delta) repeatKey=\(repeatKeyCode.map(String.init) ?? "nil")"
        )
        #endif
        NotificationCenter.default.post(
            name: .browserMoveOmnibarSelection,
            object: panelId,
            userInfo: ["delta": delta]
        )
    }

    func startOmnibarSelectionRepeatIfNeeded(keyCode: UInt16, delta: Int) {
        guard delta != 0 else { return }
        guard focusedPanelId != nil else {
            #if DEBUG
            dlog(
                "browser.focus.omnibar.repeat.start key=\(keyCode) delta=\(delta) " +
                "result=skip_no_focused_address_bar"
            )
            #endif
            return
        }

        if repeatKeyCode == keyCode, repeatDelta == delta {
            #if DEBUG
            let panelToken = focusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            dlog(
                "browser.focus.omnibar.repeat.start panel=\(panelToken) " +
                "key=\(keyCode) delta=\(delta) result=reuse"
            )
            #endif
            return
        }

        stopOmnibarSelectionRepeat()
        repeatKeyCode = keyCode
        repeatDelta = delta
        #if DEBUG
        let panelToken = focusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        dlog(
            "browser.focus.omnibar.repeat.start panel=\(panelToken) " +
            "key=\(keyCode) delta=\(delta) result=armed"
        )
        #endif

        let start = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduleOmnibarSelectionRepeatTick()
            }
        }
        repeatStartWorkItem = start
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: start)
    }

    private func scheduleOmnibarSelectionRepeatTick() {
        repeatStartWorkItem = nil
        guard focusedPanelId != nil else {
            #if DEBUG
            dlog("browser.focus.omnibar.repeat.tick result=stop_no_focused_address_bar")
            #endif
            stopOmnibarSelectionRepeat()
            return
        }
        guard repeatKeyCode != nil else { return }

        #if DEBUG
        let panelToken = focusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        dlog(
            "browser.focus.omnibar.repeat.tick panel=\(panelToken) " +
            "delta=\(repeatDelta)"
        )
        #endif
        dispatchOmnibarSelectionMove(delta: repeatDelta)

        let tick = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduleOmnibarSelectionRepeatTick()
            }
        }
        repeatTickWorkItem = tick
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.055, execute: tick)
    }

    func stopOmnibarSelectionRepeat() {
        #if DEBUG
        let previousKeyCode = repeatKeyCode
        let previousDelta = repeatDelta
        #endif
        repeatStartWorkItem?.cancel()
        repeatTickWorkItem?.cancel()
        repeatStartWorkItem = nil
        repeatTickWorkItem = nil
        repeatKeyCode = nil
        repeatDelta = 0
        #if DEBUG
        if previousKeyCode != nil || previousDelta != 0 {
            dlog(
                "browser.focus.omnibar.repeat.stop key=\(previousKeyCode.map(String.init) ?? "nil") " +
                "delta=\(previousDelta)"
            )
        }
        #endif
    }

    func handleOmnibarSelectionRepeatLifecycleEvent(_ event: NSEvent) {
        guard repeatKeyCode != nil else { return }

        switch event.type {
        case .keyUp:
            if event.keyCode == repeatKeyCode {
                #if DEBUG
                dlog(
                    "browser.focus.omnibar.repeat.lifecycle event=keyUp key=\(event.keyCode) " +
                    "action=stop"
                )
                #endif
                stopOmnibarSelectionRepeat()
            }
        case .flagsChanged:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !flags.contains(.command) {
                #if DEBUG
                dlog(
                    "browser.focus.omnibar.repeat.lifecycle event=flagsChanged " +
                    "flags=\(flags.rawValue) action=stop"
                )
                #endif
                stopOmnibarSelectionRepeat()
            }
        default:
            break
        }
    }

    // MARK: Notification observers

    func installObserversIfNeeded() {
        guard focusObserver == nil,
              blurObserver == nil,
              webViewFirstResponderObserver == nil else { return }

        focusObserver = NotificationCenter.default.addObserver(
            forName: .browserDidFocusAddressBar,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let panelId = notification.object as? UUID else { return }
                self.panelLookup(panelId)?.beginSuppressWebViewFocusForAddressBar()
                self.focusedPanelId = panelId
                self.stopOmnibarSelectionRepeat()
                #if DEBUG
                dlog("addressBar FOCUS panelId=\(panelId.uuidString.prefix(8))")
                #endif
            }
        }

        blurObserver = NotificationCenter.default.addObserver(
            forName: .browserDidBlurAddressBar,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let panelId = notification.object as? UUID else { return }
                self.panelLookup(panelId)?.endSuppressWebViewFocusForAddressBar()
                if self.focusedPanelId == panelId {
                    self.focusedPanelId = nil
                    self.stopOmnibarSelectionRepeat()
                    #if DEBUG
                    dlog("addressBar BLUR panelId=\(panelId.uuidString.prefix(8))")
                    #endif
                }
            }
        }

        webViewFirstResponderObserver = NotificationCenter.default.addObserver(
            forName: .browserDidBecomeFirstResponderWebView,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let webView = notification.object as? CmuxWebView,
                      let panel = self.panelOwnerLookup(webView) else { return }

                if let trackedPanelId = self.focusedPanelId,
                   trackedPanelId != panel.id,
                   let trackedPanel = self.panelLookup(trackedPanelId),
                   !self.shouldPreserveCheck(trackedPanel) {
                    trackedPanel.endSuppressWebViewFocusForAddressBar()
                    self.focusedPanelId = nil
                    self.stopOmnibarSelectionRepeat()
                    #if DEBUG
                    dlog(
                        "addressBar CLEAR panelId=\(trackedPanelId.uuidString.prefix(8)) " +
                        "reason=stale_other_panel_webViewFirstResponder"
                    )
                    #endif
                }

                guard !self.shouldPreserveCheck(panel) else {
                    #if DEBUG
                    dlog(
                        "addressBar CLEAR panelId=\(panel.id.uuidString.prefix(8)) " +
                        "reason=skip_preserve_omnibar_handoff"
                    )
                    #endif
                    return
                }
                panel.endSuppressWebViewFocusForAddressBar()
                if self.focusedPanelId == panel.id {
                    self.focusedPanelId = nil
                    self.stopOmnibarSelectionRepeat()
                    #if DEBUG
                    dlog(
                        "addressBar CLEAR panelId=\(panel.id.uuidString.prefix(8)) " +
                        "reason=webViewFirstResponder"
                    )
                    #endif
                }
            }
        }
    }
}
