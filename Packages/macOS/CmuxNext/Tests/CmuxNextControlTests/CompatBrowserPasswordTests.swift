import Foundation
import Testing
@testable import CmuxNextControl

/// Agent browser commands never return a password field's value: `get value`
/// answers null and a snapshot names the field without it.
@MainActor @Suite struct CompatBrowserPasswordTests {
    @Test func passwordFieldValuesStayInThePage() {
        #expect(CompatBrowserScripts.value("#pw", nil).contains("el.type === 'password') ? null"))
        let snapshot = CompatBrowserScripts.snapshot(selector: nil, maxDepth: 4, interactiveOnly: false)
        #expect(snapshot.contains("el.type==='password' ? ''"))
    }
}
