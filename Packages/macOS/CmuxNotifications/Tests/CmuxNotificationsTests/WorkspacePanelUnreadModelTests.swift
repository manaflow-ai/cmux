import Foundation
import Observation
import os
import Testing
@testable import CmuxNotifications

@Suite("Workspace panel unread model")
struct WorkspacePanelUnreadModelTests {
    @Test
    @MainActor
    func replacementInvalidatesOnlyChangedKeyedState() {
        let panelID = UUID()
        let model = WorkspacePanelUnreadModel()
        let invalidationCount = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = model.panelIds
        } onChange: {
            invalidationCount.withLock { $0 += 1 }
        }

        #expect(model.replace(with: [panelID]))
        #expect(model.panelIds == [panelID])
        #expect(invalidationCount.withLock { $0 } == 1)
        #expect(!model.replace(with: [panelID]))
    }
}
