import CmuxNextCompat
import CmuxNextPages

extension WebUIHost {
    /// A page host for an agent tab store test: no Chromium host (every page is WebKit), no open
    /// panel, its own registry.
    static func agentTabsTestHost() -> WebUIHost {
        WebUIHost(chromium: nil, openPanel: nil, memoryPressure: MemoryPressureEvents(source: ManualMemoryPressureSource()))
    }
}
