@testable import CmuxNextControl
import CmuxNextSettings
import CmuxNextCompat
import Foundation
import Testing

/// The generated registry describes both the daemon resource socket and the
/// native app control socket. Keep the latter tied to the methods the router
/// actually registers; a renamed app method must fail this test.
@Suite struct SettingsSurfaceBindingTests {
    @Test func nativeAppSocketMethodsMatchTheDescriptorRegistry() {
        let router = ControlRouter(identity: testIdentity(), executor: CountingExecutor(), configuration: .init())
        let methods = Set(router.methodNames)
        let expected = Set(["settings.get", "settings.set", "settings.reset", "settings.unset"])
        #expect(expected.isSubset(of: methods))
        for descriptor in SettingsSchema.all {
            let appMethods = Set(descriptor.surfacePlan.socket.appOperations + descriptor.surfacePlan.socket.appAliases)
            #expect(appMethods == expected, Comment(rawValue: descriptor.id))
        }
    }
}
