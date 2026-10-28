import CmuxHomeCore
import CmuxNextCloud
import CmuxNextHomeEngine
import CmuxNextHostedChief
import Foundation

#if DEBUG || CMUX_BENCH_HOOKS
/// Inputs for an isolated Home composition test, using the same values and source protocol
/// as the app. Install before first accessing AppServices.home. This does not simulate
/// sign-in, token leasing, plan entitlements, a remote daemon, or a running Chief.
/// AppServices captures also require the separate auth-capture fixture.
@MainActor
struct HomeCompositionDependencies {
    let source: any HomeSource
    let me: ParticipantID
    let user: CMUXAuthUser?
    let stackProjectID: String
    let chiefHome: ChiefHome
    let caches: URL
    let cloudChiefs: HomeCloudChiefs
    /// Installed harness IDs and their existing doctor result (true means ready).
    let harnesses: [String: Bool]
}
#endif

extension HomeService {
    var compositionSource: any HomeSource {
        #if DEBUG || CMUX_BENCH_HOOKS
        if let composition { return composition.source }
        #endif
        return homeRouter
    }

    var compositionParticipant: ParticipantID {
        #if DEBUG || CMUX_BENCH_HOOKS
        if let composition { return composition.me }
        #endif
        return homeSource.me.id
    }

    /// The same account mapping used by Home's pins and recipient directory.
    var compositionAccount: String? {
        #if DEBUG || CMUX_BENCH_HOOKS
        if let composition {
            return composition.user.map { CloudIdentity.workerUserID(stackProjectID: composition.stackProjectID, stackUserID: $0.id) }
        }
        #endif
        let auth = services.cloud.auth
        return auth.user.map { CloudIdentity.workerUserID(stackProjectID: auth.configuration.stackProjectID, stackUserID: $0.id) }
    }

    func listedHarnesses() async -> [String] {
        #if DEBUG || CMUX_BENCH_HOOKS
        if let composition { return composition.harnesses.keys.sorted() }
        #endif
        return (try? await services.agentHarnesses.listed())?.sorted() ?? []
    }

    func checkHarness(_ id: String) async -> Bool {
        #if DEBUG || CMUX_BENCH_HOOKS
        if let composition { return composition.harnesses[id] == true }
        #endif
        return (try? await services.agentHarnesses.doctor(id: id))?["ok"]?.boolValue == true
    }
}
