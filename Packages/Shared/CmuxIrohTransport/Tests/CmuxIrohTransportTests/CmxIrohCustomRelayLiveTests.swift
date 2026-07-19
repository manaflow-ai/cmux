import Foundation
import Testing
@testable import CmuxIrohTransport

/// Opt-in live checks for real custom relay address selection. CI skips this
/// suite unless `CMUX_IROH_CUSTOM_RELAY_LIVE=1` is explicitly present.
@Suite(
    .serialized,
    .enabled(if: CmxIrohCustomRelayLiveEnvironment.isEnabled)
)
struct CmxIrohCustomRelayLiveTests {
    @Test(.enabled(if: CmxIrohCustomRelayLiveEnvironment.hasNoTokenRelay))
    func unauthenticatedRelayUsesExactConfiguredURL() async throws {
        let relayURL = try CmxIrohCustomRelayLiveEnvironment.required(
            "CMUX_IROH_CUSTOM_RELAY_NO_TOKEN_URL"
        )
        let profile = CmxIrohEndpointRelayProfile(
            customProfile: try CmxIrohCustomRelayProfile(
                relays: [CmxIrohCustomRelay(url: relayURL)]
            )
        )

        let result = await CmxIrohCustomRelayProbe().probe(
            profile: profile,
            timeout: CmxIrohCustomRelayLiveEnvironment.timeout
        )

        #expect(result == .reachable(relayURL: relayURL))
    }

    @Test(.enabled(if: CmxIrohCustomRelayLiveEnvironment.hasStaticTokenRelay))
    func staticTokenProfileAdvertisesExactConfiguredURL() async throws {
        // Relay advertisement proves exact FFI map selection, not provider
        // authentication. The product does not present this as a token test.
        let relayURL = try CmxIrohCustomRelayLiveEnvironment.required(
            "CMUX_IROH_CUSTOM_RELAY_STATIC_URL"
        )
        let token = try CmxIrohCustomRelayLiveEnvironment.required(
            "CMUX_IROH_CUSTOM_RELAY_STATIC_TOKEN"
        )
        let profile = CmxIrohEndpointRelayProfile(
            customProfile: try CmxIrohCustomRelayProfile(
                relays: [
                    CmxIrohCustomRelay(
                        url: relayURL,
                        authenticationToken: token
                    ),
                ]
            )
        )

        let result = await CmxIrohCustomRelayProbe().probe(
            profile: profile,
            timeout: CmxIrohCustomRelayLiveEnvironment.timeout
        )

        #expect(result == .reachable(relayURL: relayURL))
    }
}
