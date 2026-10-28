import CmuxNextBrowser
import CmuxNextBrowserAutomation
import Foundation

/// Agent CDP straight from the browser host to the Chromium Host (task p01-process-233 of
/// plans/cmux-next/chrome-parity/p01-process.md). The browser host sends `cdp.prepare` instead of
/// `cdp.attach` while the app's Chromium Host holds a relay link: the app makes the page agent-ready
/// exactly as for its own relay (marked, rebuilt, woken, created hidden), then names the page to the
/// browser host (`tab.relay.direct`), and from then on the tab's DevTools messages never reach the app.
/// The app keeps what only it can do: the tab's agent-driven mark and its capture votes (`cdp.capture`).
/// Chrome splits the same way: the remote debugging pipe's traffic runs off the browser's UI thread
/// (content/browser/devtools/devtools_pipe_handler.cc), and only what the person sees stays on it.
extension BrowserHostProvider {
    /// `cdp.prepare`: an agent's first touch of a CEF tab whose CDP the Chromium Host relays.
    func prepareDirectRelay(_ targetID: String) {
        if let session = relays[targetID] {
            if session.direct {
                // Prepared already (the browser host opened the relay again): the same page, named again.
                // A prepare still running answers by itself.
                if case .direct = session.phase { answerDirect(targetID) }
                return
            }
            // The app relayed the tab itself until now: that relay ends, and the host's commands go to the link.
            endRelay(targetID, answering: true)
        }
        guard announced[targetID]?.engine == .cef else {
            send(.event(name: "tab.relay.failed",
                        payload: .object(["targetId": .string(targetID), "reason": .string("no Chromium tab \(targetID)")])))
            return
        }
        attachRelay(targetID, direct: true)
    }

    /// The prepared tab's page to the browser host: its browser and the Chromium Host's link id; without a
    /// link id (in process, or a host that cannot relay) the browser host relays the tab through the app.
    func answerDirect(_ targetID: String) {
        var payload: [String: DriverJSON] = ["targetId": .string(targetID)]
        if let target = relay?.directTarget(targetID: targetID) {
            payload["browser"] = .number(Double(target.browser))
            payload["link"] = .string(target.linkID)
        }
        send(.event(name: "tab.relay.direct", payload: .object(payload)))
    }

    /// `cdp.capture`: a capture command the browser host sent to the Chromium Host. The tab's capture vote
    /// starts before the page can answer, so a hidden tab renders for it, and ends at the reply. A tab a pane
    /// showed and then let go since the prepare goes back to the render window first, as the app's own relay
    /// does on each send (`AppDevToolsRelay.send`).
    func directCapture(_ targetID: String, capture kind: String, active: Bool, id: UInt64?) {
        guard let session = relays[targetID], session.direct else { return }
        if active { relay?.keepRendering(targetID: targetID) }
        switch kind {
        case "screenshot":
            guard let id else { return }
            let key = Int(truncatingIfNeeded: id)
            if active {
                guard session.screenshots[key] == nil else { return }
                relays[targetID]?.screenshots[key] = capture?.captureVote(targetID: targetID, reason: "agent.screenshot")
            } else {
                relays[targetID]?.screenshots.removeValue(forKey: key)?.release()
            }
        case "screencast":
            if active {
                guard session.screencast == nil else { return }
                relays[targetID]?.screencast = capture?.captureVote(targetID: targetID, reason: "agent.screencast")
            } else {
                relays[targetID]?.screencast?.release()
                relays[targetID]?.screencast = nil
            }
        default:
            break
        }
    }
}
