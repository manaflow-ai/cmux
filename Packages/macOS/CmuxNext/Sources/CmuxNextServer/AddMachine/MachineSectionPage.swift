public import CmuxNextPages

extension MachineSectionPageProvider {
    /// The right sidebar's Machines section: the page `cmux-page://cmux.machines/`
    /// (webviews/src/pages/machines) in a ``PageSectionHost``, served by this provider. While the section
    /// shows, this provider streams changes to the page and `joined` re-checks its online rows once their
    /// heartbeat would pass the hub's 30 s window (``JoinedMachineStore/startAging(_:visible:)``); hidden
    /// or out of the window, both stop. A covered window coming back into view restarts the aging at
    /// once; covering it stops it.
    public func makeSection(joined: JoinedMachineStore) -> PageSectionHost {
        let page = PageWebView(descriptor: .machines, routes: [PageRoute(prefix: Self.prefix, provider: self)])
        let host = PageSectionHost(page: page)
        host.setAccessibilityIdentifier("cmux.machinesSection")
        present = { [weak page] menu, point in await page?.presentMenu(menu, atPagePoint: point) }
        host.onSightChange = { visible in
            if visible { joined.resumeAging() } else { joined.pauseAging() }
        }
        host.onShownChange = { [weak self, weak host] shown in
            self?.setShown(shown)
            guard let host else { return }
            if shown {
                joined.startAging(host) { [weak host] in host?.isOnScreen ?? false }
            } else {
                joined.stopAging(host)
            }
        }
        return host
    }
}
