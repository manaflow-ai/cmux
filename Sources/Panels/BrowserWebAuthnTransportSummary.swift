struct BrowserWebAuthnTransportSummary {
    let containsBluetooth: Bool
    let containsHybrid: Bool
    let containsInternal: Bool
    let containsSecurityKeyTransport: Bool
    let containsUnspecifiedTransport: Bool

    init(descriptors: [BrowserWebAuthnCredentialDescriptor]) {
        var containsBluetooth = false
        var containsHybrid = false
        var containsInternal = false
        var containsSecurityKeyTransport = false
        var containsUnspecifiedTransport = false

        for descriptor in descriptors where descriptor.isPublicKeyCredential {
            let transports = descriptor.normalizedTransports
            if transports.isEmpty {
                containsUnspecifiedTransport = true
                continue
            }

            for transport in transports {
                switch transport {
                case .ble:
                    containsBluetooth = true
                    containsSecurityKeyTransport = true
                case .hybrid:
                    containsHybrid = true
                case .internal:
                    containsInternal = true
                case .nfc, .usb:
                    containsSecurityKeyTransport = true
                }
            }
        }

        self.containsBluetooth = containsBluetooth
        self.containsHybrid = containsHybrid
        self.containsInternal = containsInternal
        self.containsSecurityKeyTransport = containsSecurityKeyTransport
        self.containsUnspecifiedTransport = containsUnspecifiedTransport
    }

    var debugSummary: String {
        "bt=\(containsBluetooth) hybrid=\(containsHybrid) internal=\(containsInternal) " +
            "securityKey=\(containsSecurityKeyTransport) unspecified=\(containsUnspecifiedTransport)"
    }

    var allowsPlatformCredentials: Bool {
        containsInternal || containsUnspecifiedTransport
    }

    var allowsSecurityKeyCredentials: Bool {
        containsSecurityKeyTransport || containsUnspecifiedTransport
    }

    var needsBluetoothPreparation: Bool {
        containsBluetooth
    }

    var shouldShowHybridTransport: Bool {
        containsUnspecifiedTransport
    }

    var prefersSecurityKeysFirst: Bool {
        containsSecurityKeyTransport && !containsInternal && !containsHybrid && !containsUnspecifiedTransport
    }
}
