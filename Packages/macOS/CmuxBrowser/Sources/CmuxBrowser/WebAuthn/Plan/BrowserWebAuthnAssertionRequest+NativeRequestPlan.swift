public import AuthenticationServices
#if DEBUG
internal import CMUXDebugLog
#endif

extension BrowserWebAuthnAssertionRequest {
    /// Builds the native authorization plan for this credential-assertion request,
    /// or nil when no platform or security-key request is available on this OS.
    @MainActor
    public func nativeRequestPlan(
        clientDataContext: BrowserWebAuthnClientDataContext
    ) throws -> BrowserWebAuthnNativeRequestPlan? {
        guard let relyingPartyIdentifier = try clientDataContext.resolveRelyingPartyIdentifier(
            publicKey.rpId
        ) else {
            return nil
        }
        let clientData = try clientDataContext.clientData(challenge: publicKey.challenge.data)
        let allowCredentials = (publicKey.allowCredentials ?? []).filter(\.isPublicKeyCredential)
        let transportSummary = BrowserWebAuthnTransportSummary(descriptors: allowCredentials)
        let userVerificationPreference = publicKey.normalizedUserVerificationPreference

        let includePlatformRequests =
            allowCredentials.isEmpty || transportSummary.allowsPlatformCredentials
        let includeSecurityKeyRequests =
            allowCredentials.isEmpty || transportSummary.allowsSecurityKeyCredentials

        var platformRequests: [ASAuthorizationRequest] = []
        if includePlatformRequests,
           #available(macOS 13.5, *) {
            let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
                relyingPartyIdentifier: relyingPartyIdentifier
            )
            let platformRequest = provider.createCredentialAssertionRequest(clientData: clientData)
            platformRequest.userVerificationPreference = .init(rawValue: userVerificationPreference)

            let allowedCredentials = allowCredentials.compactMap { descriptor -> ASAuthorizationPlatformPublicKeyCredentialDescriptor? in
                if descriptor.normalizedTransports.isEmpty {
                    return descriptor.platformDescriptor()
                }

                let transports = Set(descriptor.normalizedTransports)
                guard transports.contains(.internal) || transports.contains(.hybrid) else {
                    return nil
                }
                return descriptor.platformDescriptor()
            }
            if !allowedCredentials.isEmpty {
                platformRequest.allowedCredentials = allowedCredentials
            }
            platformRequest.shouldShowHybridTransport =
                allowCredentials.isEmpty ? true : transportSummary.shouldShowHybridTransport
            platformRequests.append(platformRequest)
        }

        var securityKeyRequests: [ASAuthorizationRequest] = []
        if includeSecurityKeyRequests,
           #available(macOS 14.4, *) {
            let provider = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(
                relyingPartyIdentifier: relyingPartyIdentifier
            )
            let securityKeyRequest = provider.createCredentialAssertionRequest(clientData: clientData)
            securityKeyRequest.userVerificationPreference = .init(rawValue: userVerificationPreference)
            let allowedCredentials = allowCredentials.compactMap { $0.securityKeyDescriptor() }
            if !allowedCredentials.isEmpty {
                securityKeyRequest.allowedCredentials = allowedCredentials
            }
            if #available(macOS 14.5, *),
               let appID = publicKey.extensions?.appid,
               !appID.isEmpty {
                securityKeyRequest.appID = appID
            }
            securityKeyRequests.append(securityKeyRequest)
        }

        guard !platformRequests.isEmpty || !securityKeyRequests.isEmpty else {
            #if DEBUG
            CMUXDebugLog.logDebugEvent("webauthn.buildAssertionPlan no requests built — returning nil")
            #endif
            return nil
        }

        let order: BrowserWebAuthnRequestOrder =
            transportSummary.prefersSecurityKeysFirst ? .securityKeyFirst : .platformFirst
        let needsBluetoothForPlatformRequests =
            allowCredentials.isEmpty ? true : transportSummary.shouldShowHybridTransport

        #if DEBUG
        CMUXDebugLog.logDebugEvent("webauthn.buildAssertionPlan rp=\(relyingPartyIdentifier) platform=\(platformRequests.count) securityKey=\(securityKeyRequests.count) allowCredentials=\(allowCredentials.count) mediation=\(mediation ?? "(nil)") hybridTransport=\(transportSummary.shouldShowHybridTransport)")
        #endif
        return .init(
            platformRequests: platformRequests,
            securityKeyRequests: securityKeyRequests,
            order: order,
            needsBluetoothForPlatformRequests: needsBluetoothForPlatformRequests,
            needsBluetoothForSecurityKeyRequests: transportSummary.containsBluetooth,
            prefersImmediatelyAvailableCredentials: mediation == "conditional"
        )
    }
}
