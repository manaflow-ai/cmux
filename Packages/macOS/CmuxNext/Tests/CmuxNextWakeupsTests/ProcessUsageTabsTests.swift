import CmuxNextWakeups
import Darwin
import Testing

/// Renderer CPU, wakeups and energy grouped per tab. A renderer serves a tab when it hosts
/// its main frame (the fork's pid) or any of its frames (a renderer client id); same-site tabs share one
/// renderer and both show its whole usage, and the renderer names both.
@Suite struct ProcessUsageTabsTests {
    private static func usage(_ pid: pid_t, cpu: UInt64, interrupt: UInt64, energy: UInt64) -> ProcessUsage {
        ProcessUsage(pid: pid, parent: 1, path: "/Applications/cmux NEXT.app/Contents/Frameworks/cmux Helper (Renderer).app",
                     cpuNanos: cpu, wakeups: interrupt, interruptWakeups: interrupt, packageIdleWakeups: interrupt / 2,
                     energyNanojoules: energy, physFootprint: 0, uptimeNanos: 0)
    }

    @Test func twoTabsOnOneRendererBothShowItsUsageAndItNamesBoth() throws {
        let tabs = [
            ProcessUsage.TabRenderers(tab: "a", title: "Docs", pid: 501, rendererClients: [3]),
            ProcessUsage.TabRenderers(tab: "b", title: "Docs 2", pid: 501, rendererClients: [3]),
            ProcessUsage.TabRenderers(tab: "c", title: "Other", pid: 502, rendererClients: [4]),
        ]
        let shared = Self.usage(501, cpu: 9_000_000, interrupt: 40, energy: 7_000)
        let other = Self.usage(502, cpu: 1_000_000, interrupt: 2, energy: 100)
        let grouped = ProcessUsage.perTab(tabs, renderers: [
            (renderer: ProcessUsage.Renderer(pid: 501, clientID: 3), usage: shared),
            (renderer: ProcessUsage.Renderer(pid: 502, clientID: 4), usage: other),
        ])
        try #require(grouped.map(\.tab) == ["a", "b", "c"])
        for row in grouped.prefix(2) {
            #expect(row.renderers.map(\.renderer.pid) == [501])
            #expect(row.renderers.first?.tabs == ["a", "b"])
            #expect(row.cpuNanos == 9_000_000)
            #expect(row.interruptWakeups == 40)
            #expect(row.packageIdleWakeups == 20)
            #expect(row.energyNanojoules == 7_000)
        }
        #expect(grouped[2].renderers.map(\.renderer.pid) == [502])
        #expect(grouped[2].renderers.first?.tabs == ["c"])
    }

    /// Without the fork's pid (an older fork, before the pin), a renderer serves a tab through its client id.
    @Test func aClientIDAloneAttributesTheRenderer() {
        let tab = ProcessUsage.TabRenderers(tab: "a", title: "Docs", pid: nil, rendererClients: [3])
        #expect(tab.isServed(by: ProcessUsage.Renderer(pid: 501, clientID: 3)))
        #expect(!tab.isServed(by: ProcessUsage.Renderer(pid: 501, clientID: 4)))
    }

    /// An out-of-process iframe's renderer is the tab's too, next to its main frame's.
    @Test func anOutOfProcessFrameAddsItsRenderer() {
        let tabs = [ProcessUsage.TabRenderers(tab: "a", title: "Docs", pid: 501, rendererClients: [3, 9])]
        let grouped = ProcessUsage.perTab(tabs, renderers: [
            (renderer: ProcessUsage.Renderer(pid: 501, clientID: 3), usage: Self.usage(501, cpu: 2, interrupt: 2, energy: 2)),
            (renderer: ProcessUsage.Renderer(pid: 509, clientID: 9), usage: Self.usage(509, cpu: 3, interrupt: 3, energy: 3)),
            (renderer: ProcessUsage.Renderer(pid: 510, clientID: 10), usage: Self.usage(510, cpu: 5, interrupt: 5, energy: 5)),
        ])
        #expect(grouped.first?.renderers.map(\.renderer.pid) == [501, 509])
        #expect(grouped.first?.cpuNanos == 5)
    }

    @Test func aTabNoSampledRendererServesHasNone() {
        let tabs = [ProcessUsage.TabRenderers(tab: "a", title: "Docs", pid: nil, rendererClients: [])]
        let grouped = ProcessUsage.perTab(tabs, renderers: [
            (renderer: ProcessUsage.Renderer(pid: 501, clientID: 3), usage: Self.usage(501, cpu: 2, interrupt: 2, energy: 2)),
        ])
        #expect(grouped.first?.renderers.isEmpty == true)
        #expect(grouped.first?.cpuNanos == 0)
    }

    /// The App publishes one tab at a time and drops the tabs it closed; the snapshot is ordered by tab id.
    @Test func theDirectoryKeepsTheLatestOfEachOpenTab() {
        let directory = TabRendererDirectory()
        directory.update(ProcessUsage.TabRenderers(tab: "b", title: "Loading", pid: nil, rendererClients: []))
        directory.update(ProcessUsage.TabRenderers(tab: "a", title: "Docs", pid: 501, rendererClients: [3]))
        directory.update(ProcessUsage.TabRenderers(tab: "b", title: "News", pid: 502, rendererClients: [4]))
        let read = directory.snapshot()
        #expect(read.map(\.tab) == ["a", "b"])
        #expect(read.last == ProcessUsage.TabRenderers(tab: "b", title: "News", pid: 502, rendererClients: [4]))
        directory.keep(only: ["b"])
        #expect(directory.snapshot().map(\.tab) == ["b"])
    }
}
