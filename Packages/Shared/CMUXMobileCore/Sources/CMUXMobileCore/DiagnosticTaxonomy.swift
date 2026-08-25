import Foundation

/// The app transport involved in a diagnostic event.
///
/// Raw values are stable export vocabulary. Append new cases; never renumber
/// an existing case.
public enum DiagnosticTransportKind: Int, Sendable, Codable, CaseIterable {
    case unknown = 0
    case iroh = 1
    case tailscale = 2
    case websocket = 3
    case debugLoopback = 4

    /// Maps a pairing-route transport without preserving its address or other
    /// route metadata.
    public init(_ kind: CmxAttachTransportKind) {
        switch kind {
        case .iroh:
            self = .iroh
        case .tailscale:
            self = .tailscale
        case .websocket:
            self = .websocket
        case .debugLoopback:
            self = .debugLoopback
        }
    }
}

public extension CmxAttachTransportKind {
    /// A privacy-safe integer category suitable for diagnostic payloads.
    var diagnosticTransportKind: DiagnosticTransportKind {
        DiagnosticTransportKind(self)
    }
}

/// A stable, privacy-safe classification for connection failures.
///
/// This vocabulary intentionally excludes raw error text, addresses, endpoint
/// IDs, account data, and provider responses. Unknown errors remain
/// ``unknown`` instead of being serialized as strings.
public enum DiagnosticFailureKind: Int, Sendable, Codable, CaseIterable {
    case none = 0
    case offline = 1
    case timedOut = 2
    case connectionRefused = 3
    case hostUnreachable = 4
    case permissionDenied = 5
    case dnsFailed = 6
    case secureChannelFailed = 7
    case unsupportedRoute = 8
    case noRoute = 9
    case credentialUnavailable = 10
    case policyUnavailable = 11
    case endpointUnavailable = 12
    case identityMismatch = 13
    case admissionDenied = 14
    case authorizationFailed = 15
    case accountMismatch = 16
    case protocolViolation = 17
    case connectionClosed = 18
    case superseded = 19
    case cancelled = 20
    /// The established transport exceeded its negotiated inactivity window.
    case transportIdleTimedOut = 21
    /// Online admission closed the session because its signed lease expired.
    case admissionLeaseExpired = 22
    /// Online admission closed the session after broker revalidation failed.
    case admissionRevalidationFailed = 23
    /// The local side closed an admitted session because its bounded outbound
    /// event queue overflowed while the transport stopped draining (for
    /// example the peer's network path died mid-write).
    case sendQueueOverflow = 24
    /// The connect-attempt registry refused a dial because the exact route is
    /// held by an in-flight connect attempt. Distinguishes gate refusals from
    /// genuine dial timeouts in exports; a gated attempt never reached the
    /// network.
    case routeGated = 25
    /// A bounded operation rejected one input because its payload exceeded the
    /// supported per-item size. The payload itself is never retained.
    case payloadTooLarge = 26
    /// A bounded operation could not admit more work because its item-count or
    /// aggregate byte budget was already exhausted.
    case resourceLimitReached = 27
    /// An attachment picker or composer reached its fixed item-count cap.
    case attachmentCountLimitReached = 28
    /// An attachment picker or composer reached its aggregate byte budget.
    case attachmentAggregateSizeLimitReached = 29
    /// Required device-local persisted state was absent or unavailable.
    case localStateUnavailable = 30
    case unknown = 255

    /// Reduces a typed or system error to the bounded diagnostic vocabulary.
    ///
    /// Domain-specific errors should conform to ``DiagnosticFailureProviding``
    /// so their mapping stays close to the source. The fallback recognizes only
    /// stable Foundation/POSIX codes and never retains the error's description.
    public static func classify(_ error: any Error) -> DiagnosticFailureKind {
        if let providing = error as? any DiagnosticFailureProviding {
            return providing.diagnosticFailureKind
        }
        if error is CancellationError {
            return .cancelled
        }

        let error = error as NSError
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorInternationalRoamingOff,
                 NSURLErrorDataNotAllowed:
                return .offline
            case NSURLErrorTimedOut:
                return .timedOut
            case NSURLErrorCannotConnectToHost:
                return .connectionRefused
            case NSURLErrorCannotFindHost,
                 NSURLErrorDNSLookupFailed:
                return .dnsFailed
            case NSURLErrorSecureConnectionFailed,
                 NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid,
                 NSURLErrorClientCertificateRejected,
                 NSURLErrorClientCertificateRequired:
                return .secureChannelFailed
            case NSURLErrorUserAuthenticationRequired:
                return .authorizationFailed
            case NSURLErrorNetworkConnectionLost:
                return .connectionClosed
            case NSURLErrorCancelled:
                return .cancelled
            default:
                return .unknown
            }
        }

        if error.domain == NSPOSIXErrorDomain {
            switch error.code {
            case Int(POSIXErrorCode.ECONNREFUSED.rawValue):
                return .connectionRefused
            case Int(POSIXErrorCode.EHOSTUNREACH.rawValue),
                 Int(POSIXErrorCode.ENETUNREACH.rawValue):
                return .hostUnreachable
            case Int(POSIXErrorCode.ETIMEDOUT.rawValue):
                return .timedOut
            case Int(POSIXErrorCode.EACCES.rawValue),
                 Int(POSIXErrorCode.EPERM.rawValue):
                return .permissionDenied
            case Int(POSIXErrorCode.ECONNRESET.rawValue),
                 Int(POSIXErrorCode.EPIPE.rawValue),
                 Int(POSIXErrorCode.ENOTCONN.rawValue):
                return .connectionClosed
            case Int(POSIXErrorCode.ECANCELED.rawValue):
                return .cancelled
            default:
                return .unknown
            }
        }

        return .unknown
    }
}

/// Why a pending transport dial was cancelled by its owner.
///
/// This is deliberately separate from ``DiagnosticFailureKind/cancelled``:
/// the failure says what the transport observed, while this value says which
/// lifecycle boundary asked it to stop.
public enum DiagnosticCancellationReason: Int, Sendable, Codable, CaseIterable {
    case unknown = 0
    case requestCancelled = 1
    case requestTimedOut = 2
    case sessionTeardown = 3
    case sessionDeinitialized = 4
}

/// The bounded reason token sent by an admitted Iroh peer when it closes.
///
/// Raw Iroh close text is never exported. The server and client agree on these
/// tokens so a report can distinguish an expected replacement from a network
/// failure without retaining a peer-chosen string.
public enum DiagnosticRemoteCloseReason: Int, Sendable, Codable, CaseIterable {
    case unknown = 0
    case clientClosed = 1
    case serverClosed = 2
    case superseded = 3
    case admissionLeaseExpired = 4
    case admissionRevalidationFailed = 5
    case sendQueueOverflow = 6
    case serverFailure = 7
    case serverCancelled = 8
}

/// Adopted by transport and policy errors that can provide a safe failure
/// category without exporting their raw associated values or description.
public protocol DiagnosticFailureProviding: Error, Sendable {
    var diagnosticFailureKind: DiagnosticFailureKind { get }
}

/// The network path selected underneath an app transport.
public enum DiagnosticPathKind: Int, Sendable, Codable, CaseIterable {
    case unknown = 0
    case direct = 1
    case relay = 2
    case privateNetwork = 3
    case loopback = 4

    /// Redacts a live Iroh path to its connection class. Managed and custom
    /// relay metadata intentionally collapse to the same ``relay`` value.
    public init(_ path: CmxIrohSelectedTransportPath) {
        switch path {
        case .unavailable:
            self = .unknown
        case .direct:
            self = .direct
        case .privateNetwork:
            self = .privateNetwork
        case .managedRelay, .customRelay:
            self = .relay
        }
    }
}

/// The dial leg attempted while establishing a direct Iroh connection.
///
/// Raw values are stable export vocabulary; never renumber.
public enum DiagnosticDirectDialLeg: Int, Sendable, Codable, CaseIterable {
    /// Broker-published public path hints.
    case publicPaths = 0
    /// Profile-gated private fallback hints (manual, LAN, or VPN sourced).
    case privateFallback = 1
}

/// Whether configured private addresses became dialable hints for one dial.
///
/// Raw values are stable export vocabulary. The cases carry only the join
/// outcome, never an address, port, or identity.
public enum DiagnosticPrivateAddressJoinState: Int, Sendable, Codable, CaseIterable {
    /// No enabled private address is configured for the target Mac.
    case notConfigured = 0
    /// At least one configured address joined a fresh broker UDP port.
    case joined = 1
    /// Addresses are configured but the target's broker-registered ports
    /// were missing or older than the private-hint TTL, so none joined.
    case brokerPortsStale = 2
}

/// The outcome of account-private LAN discovery for one dial.
///
/// Raw values are stable export vocabulary; the cases carry no peer,
/// address, or service identity.
public enum DiagnosticLANDiscoveryOutcome: Int, Sendable, Codable, CaseIterable {
    /// No broker-issued LAN authority exists for the target, so no browse ran.
    case noAuthority = 0
    /// The target Mac's advertisement resolved to dialable hints.
    case found = 1
    /// The browse completed without resolving the target's advertisement.
    case notFound = 2
    /// The system denied Bonjour browsing (Local Network permission).
    case policyDenied = 3
}

/// The Mac-side account-private Bonjour publication state.
///
/// Raw values are stable export vocabulary mirroring the publisher's
/// lifecycle without exposing any advertised name, address, or port.
public enum DiagnosticLANPublicationState: Int, Sendable, Codable, CaseIterable {
    /// Publication is stopped.
    case inactive = 0
    /// Advertisements are registered on at least one interface.
    case active = 1
    /// Registration is wanted but currently failing.
    case unavailable = 2
    /// The system denied Bonjour publication (Local Network policy).
    case policyDenied = 3
}

/// Why an admitted transport session entered or left its local pool.
///
/// Raw values are stable export vocabulary. The cases identify only local
/// lifecycle ownership, never a peer, endpoint, address, account, or raw error.
public enum DiagnosticSessionLifecycleKind: Int, Sendable, Codable, CaseIterable {
    /// A newly authenticated session entered the pool.
    case established = 1
    /// The RPC owner intentionally relinquished its control stream.
    case controlOwnerReleased = 2
    /// The RPC control reader failed and relinquished ownership.
    case controlReadFailed = 3
    /// The RPC control writer failed and relinquished ownership.
    case controlWriteFailed = 4
    /// The transport reported that its peer connection closed.
    case remoteClosed = 5
    /// A caller found a cached session already closed before its watcher ran.
    case closedSessionEvicted = 6
    /// An application-lane operation found the shared connection closed.
    case applicationLaneFailed = 7
    /// The account-scoped runtime stopped.
    case runtimeDeactivated = 8
    /// The runtime generation changed and replaced its prior sessions.
    case runtimeReconfigured = 9
    /// A caller explicitly invalidated one exact peer session.
    case explicitlyInvalidated = 10
    /// Every usable transport path disappeared from an admitted session.
    case allPathsClosed = 11
}

/// Which component produced a diagnostic report.
public enum DiagnosticRuntimeRole: Int, Sendable, Codable, CaseIterable {
    case unspecified = 0
    case mobileClient = 1
    case macHost = 2
    case broker = 3
    case relay = 4

    /// Source-level spelling used by the current Apple mobile composition.
    public static let iosClient = DiagnosticRuntimeRole.mobileClient
}

/// Stable, privacy-safe iOS product events written to the durable app log.
///
/// Each case names a feature boundary and outcome without carrying the user's
/// content or identity. Raw values are shipped diagnostic vocabulary: append
/// new cases physically at the end and never renumber existing ones. Stable
/// declaration order also prevents stale incremental clients from constructing
/// a case with a different enum discriminator. Gaps reserve room for each
/// product area so future events remain easy to audit in exported logs.
///
/// `DiagnosticEvent.c` has one stable contract per event. Categorical values
/// use ``DiagnosticAppEventDetail``. Numeric producers use `count` only for a
/// documented item count, byte count, ordinal, boolean, or bounded setting.
public enum DiagnosticAppEventKind: Int, Sendable, Codable, CaseIterable {
    // MARK: App runtime (1-19)
    case appLaunched = 1
    case appForegrounded = 2
    case appBecameInactive = 3
    case appBackgrounded = 4
    case appOpenURLReceived = 5
    case appOpenURLDeferredForAuthentication = 6
    case appOpenURLHandled = 7
    case appOpenURLRejected = 8
    case appMemoryWarningReceived = 9
    case appProtectedDataUnavailable = 10
    case appProtectedDataAvailable = 11
    case appScreenshotCaptured = 12

    // MARK: Authentication and account (20-39)
    case authRestoreStarted = 20
    case authRestoreSucceeded = 21
    case authRestoreFailed = 22
    case authSignInStarted = 23
    case authCodeRequested = 24
    case authCodeRequestFailed = 25
    case authVerificationStarted = 26
    case authSignInSucceeded = 27
    case authSignInFailed = 28
    case authSignInCancelled = 29
    case authSignOutStarted = 30
    case authSignOutSucceeded = 31
    case authSignOutFailed = 32
    case authTeamChanged = 33
    case authAccountDeletionStarted = 34
    case authAccountDeletionSucceeded = 35
    case authAccountDeletionFailed = 36
    case authRevalidationStarted = 37
    case authRevalidationSucceeded = 38
    case authRevalidationFailed = 39

    // MARK: Onboarding and migration (40-59)
    case onboardingStarted = 40
    case onboardingStageViewed = 41
    case onboardingConnectionMethodChanged = 42
    case onboardingPairingStarted = 43
    case onboardingConnectionRetried = 44
    case onboardingSkipped = 45
    case onboardingCompleted = 46
    case autoConnectMigrationPresented = 47
    case autoConnectMigrationAccepted = 48
    case autoConnectMigrationDismissed = 49

    // MARK: Push notifications (60-99)
    case pushConfigured = 60
    case pushAuthorizationPrompted = 61
    case pushAuthorizationGranted = 62
    case pushAuthorizationDenied = 63
    case pushRemoteRegistrationRequested = 64
    case pushDeviceTokenReceived = 65
    case pushDeviceTokenRegistrationFailed = 66
    case pushBackendSyncStarted = 67
    case pushBackendSyncSucceeded = 68
    case pushBackendSyncFailed = 69
    case pushReceivedInForeground = 70
    case pushPresentedInForeground = 71
    case pushSuppressedInForeground = 72
    case pushTapped = 73
    case pushReplyStarted = 74
    case pushReplySucceeded = 75
    case pushReplyFailed = 76
    case pushDismissStarted = 77
    case pushDismissSucceeded = 78
    case pushDismissFailed = 79
    case pushRemoteDismissReceived = 80
    case pushRemoteDismissApplied = 81
    case pushDeeplinkParked = 82
    case pushDeeplinkResolved = 83
    case pushDeeplinkExpired = 84
    case pushDeeplinkFailed = 85
    case pushDisabled = 86

    // MARK: Computers and pairing (100-129)
    case pairingStarted = 100
    case pairingSucceeded = 101
    case pairingFailed = 102
    case pairingCancelled = 103
    case computerListRefreshStarted = 104
    case computerListRefreshSucceeded = 105
    case computerListRefreshFailed = 106
    case computerSelected = 107
    case computerHidden = 108
    case computerUnhidden = 109
    case computerForgetStarted = 110
    case computerForgetSucceeded = 111
    case computerForgetFailed = 112
    case computerAliasChanged = 113
    case computerRoutesUpdated = 114
    case tailscaleStatusChanged = 116
    case computerSwitchStarted = 117
    case computerSwitchSucceeded = 118
    case computerSwitchFailed = 119
    case reconnectStarted = 120
    case reconnectSucceeded = 121
    case reconnectFailed = 122
    case presenceStreamStarted = 123
    case presenceStreamUpdated = 124
    case presenceStreamFailed = 125
    case deviceRegistryLoadStarted = 126
    case deviceRegistryLoadSucceeded = 127
    case deviceRegistryLoadFailed = 128
    case connectionStateChanged = 129

    // MARK: Workspaces and groups (130-179)
    case workspaceListRefreshStarted = 130
    case workspaceListRefreshSucceeded = 131
    case workspaceListRefreshFailed = 132
    case workspaceStateSyncStarted = 133
    case workspaceStateSyncSucceeded = 134
    case workspaceStateSyncFailed = 135
    case workspaceStateSyncFellBack = 136
    case workspaceOpenStarted = 137
    case workspaceOpenSucceeded = 138
    case workspaceOpenFailed = 139
    case workspaceCreateStarted = 140
    case workspaceCreateSucceeded = 141
    case workspaceCreateFailed = 142
    case workspaceRenameStarted = 143
    case workspaceRenameSucceeded = 144
    case workspaceRenameFailed = 145
    case workspaceCloseStarted = 146
    case workspaceCloseSucceeded = 147
    case workspaceCloseFailed = 148
    case workspaceMoveStarted = 149
    case workspaceMoveSucceeded = 150
    case workspaceMoveFailed = 151
    case workspaceReorderStarted = 152
    case workspaceReorderSucceeded = 153
    case workspaceReorderFailed = 154
    case workspaceReadStateChanged = 155
    case workspaceReadStateChangeFailed = 156
    case workspaceGroupCreateStarted = 157
    case workspaceGroupCreateSucceeded = 158
    case workspaceGroupCreateFailed = 159
    case workspaceGroupRenameStarted = 160
    case workspaceGroupRenameSucceeded = 161
    case workspaceGroupRenameFailed = 162
    case workspaceGroupDeleteStarted = 163
    case workspaceGroupDeleteSucceeded = 164
    case workspaceGroupDeleteFailed = 165
    case workspaceCustomizationChanged = 166
    case workspaceCustomizationChangeFailed = 167
    case workspaceSortChanged = 168
    case workspaceComputerOrderChanged = 169
    case workspaceDragDropStarted = 170
    case workspaceDragDropSucceeded = 171
    case workspaceDragDropFailed = 172
    case workspaceListRecoveryStarted = 173
    case workspaceListRecoverySucceeded = 174
    case workspaceListRecoveryFailed = 175
    case workspaceMutationUnavailable = 176
    case workspaceMutationCancelled = 177
    case workspaceGroupCollapsedChanged = 178
    case workspaceListFilterChanged = 179

    // MARK: Surfaces and navigation (180-199)
    case surfaceSelected = 180
    case surfaceListUpdated = 181
    case surfaceFocused = 182
    case surfaceCloseStarted = 183
    case surfaceCloseSucceeded = 184
    case surfaceCloseFailed = 185
    case surfaceTitleChanged = 186
    case primaryTabSelected = 187
    case searchPresented = 188
    case searchDismissed = 189
    case searchResultSelected = 190

    // MARK: Terminal (200-239)
    case terminalMounted = 200
    case terminalUnmounted = 201
    case terminalStreamSubscribed = 202
    case terminalStreamResubscribed = 203
    case terminalStreamEnded = 204
    case terminalReplayStarted = 205
    case terminalReplaySucceeded = 206
    case terminalReplayFailed = 207
    case terminalReplayRetried = 208
    case terminalInputSubmitted = 209
    case terminalInputSent = 210
    case terminalInputAcknowledged = 211
    case terminalInputDropped = 212
    case terminalOutputReceived = 213
    case terminalOutputGapDetected = 214
    case terminalRenderLagDetected = 215
    case terminalViewportChanged = 216
    case terminalViewportReportSucceeded = 217
    case terminalViewportReportFailed = 218
    case terminalScrollSent = 219
    case terminalScrollFailed = 220
    case terminalThemeChanged = 221
    /// Detail: ``DiagnosticAppEventDetail/terminalZoomAction(_:)``.
    case terminalZoomChanged = 222
    /// Detail: ``DiagnosticAppEventDetail/terminalToolbarAction(_:)``.
    case terminalToolbarActionUsed = 223
    case terminalCreateStarted = 224
    case terminalCreateSucceeded = 225
    case terminalCreateFailed = 226
    case terminalClosed = 227
    case terminalAlternateScreenChanged = 228
    case terminalTextViewOpened = 229
    case terminalArtifactGalleryOpened = 230
    case terminalArtifactListLoaded = 231
    case terminalArtifactLoadFailed = 232

    // MARK: Task composer and agent launch (240-279)
    case taskComposerOpened = 240
    case taskComposerClosed = 241
    case taskDraftChanged = 242
    case taskProviderSelected = 243
    case taskModelListLoadStarted = 244
    case taskModelListLoadSucceeded = 245
    case taskModelListLoadFailed = 246
    case taskModelSelected = 247
    case taskDirectorySearchStarted = 248
    case taskDirectorySearchSucceeded = 249
    case taskDirectorySearchFailed = 250
    case taskAttachmentPickerOpened = 251
    case taskAttachmentPrepared = 252
    case taskAttachmentPreparationFailed = 253
    case taskAttachmentRemoved = 254
    case taskSubmitStarted = 255
    case taskSubmitSucceeded = 256
    case taskSubmitFailed = 257
    case taskSubmitCancelled = 258
    case taskWorkspaceCreated = 259
    case taskAgentLaunched = 260
    case taskTemplateListLoaded = 261
    case taskTemplateCreated = 262
    case taskTemplateUpdated = 263
    case taskTemplateDeleted = 264
    case taskMachineSelected = 265
    case taskRouteSelected = 266
    case taskComposerRecoveryStarted = 267
    case taskComposerRecovered = 268
    case taskComposerRecoveryFailed = 269
    /// Count is the admitted attachment count for
    /// ``DiagnosticFailureKind/attachmentCountLimitReached`` and aggregate
    /// bytes for ``DiagnosticFailureKind/attachmentAggregateSizeLimitReached``.
    case taskAttachmentLimitReached = 270

    // MARK: Agent chat (280-309)
    case chatOpened = 280
    case chatClosed = 281
    case chatSessionListLoadStarted = 282
    case chatSessionListLoadSucceeded = 283
    case chatSessionListLoadFailed = 284
    case chatSessionSelected = 285
    case chatEventStreamStarted = 286
    case chatEventStreamEnded = 287
    case chatMessageSubmitStarted = 289
    case chatMessageSubmitSucceeded = 290
    case chatMessageSubmitFailed = 291
    case chatPermissionAnswered = 292
    case chatQuestionAnswered = 293
    case chatArtifactDiscovered = 294
    case chatArtifactOpened = 295
    case chatMessageRetried = 296
    case chatComposerAttachmentAdded = 297
    case chatComposerAttachmentRemoved = 298
    case chatBlockDetailOpened = 299
    case chatPermissionAnswerFailed = 300
    case chatQuestionAnswerFailed = 301
    case chatMessageQueued = 560
    case chatInterruptSucceeded = 561
    case chatInterruptFailed = 562
    case chatHistoryLoadStarted = 563
    case chatHistoryLoadSucceeded = 564
    case chatHistoryLoadFailed = 565
    case chatOlderHistoryLoadStarted = 566
    case chatOlderHistoryLoadSucceeded = 567
    case chatOlderHistoryLoadFailed = 568

    // MARK: Notification feed (310-339)
    case notificationFeedOpened = 310
    case notificationFeedClosed = 311
    case notificationFeedLoadStarted = 312
    case notificationFeedLoadSucceeded = 313
    case notificationFeedLoadFailed = 314
    case notificationFeedLoadMoreStarted = 315
    case notificationFeedLoadMoreSucceeded = 316
    case notificationFeedItemOpened = 318
    case notificationFeedItemMarkedRead = 319
    case notificationFeedItemDismissed = 320
    case notificationBadgeReconciled = 324
    case notificationBadgeReconcileFailed = 325
    case phonePushTestStarted = 327
    case phonePushTestSucceeded = 328
    case phonePushTestFailed = 329
    case notificationFeedFilterChanged = 330

    // MARK: Changes and diffs (340-369)
    case changesOpened = 340
    case changesClosed = 341
    case changesSummaryLoadStarted = 342
    case changesSummaryLoadSucceeded = 343
    case changesSummaryLoadFailed = 344
    case changedFilesLoadStarted = 345
    case changedFilesLoadSucceeded = 346
    case changedFilesLoadFailed = 347
    case fileDiffLoadStarted = 348
    case fileDiffLoadSucceeded = 349
    case fileDiffLoadFailed = 350
    /// Count is the zero-based file ordinal in the already-redacted list.
    case fileDiffExpanded = 351
    case fileDiffCacheHit = 352
    case changedFileSelected = 353
    case diffCopied = 354

    // MARK: Artifacts and files (370-399)
    case artifactListLoadStarted = 370
    case artifactListLoadSucceeded = 371
    case artifactListLoadFailed = 372
    case artifactOpened = 373
    case artifactDownloadStarted = 374
    case artifactDownloadSucceeded = 375
    case artifactDownloadFailed = 376
    case artifactShareStarted = 377
    case artifactShareSucceeded = 378
    case artifactShareFailed = 379
    case artifactPreviewFailed = 380
    case artifactSearchChanged = 381
    case artifactFolderOpened = 382
    case artifactCopied = 383
    case artifactQuickLookOpened = 385
    case artifactCacheHit = 386
    case artifactStreamInterrupted = 387
    case artifactSaveStarted = 388
    case artifactSaveSucceeded = 389
    case artifactSaveFailed = 390

    // MARK: Browser (400-429)
    case browserListRefreshStarted = 400
    case browserListRefreshSucceeded = 401
    case browserListRefreshFailed = 402
    case browserCreateStarted = 403
    case browserCreateSucceeded = 404
    case browserCreateFailed = 405
    case browserStreamStartRequested = 406
    case browserStreamStarted = 407
    case browserStreamStartFailed = 408
    case browserStreamStopped = 409
    case browserStreamRestarted = 410
    case browserNavigateStarted = 411
    case browserNavigateSucceeded = 412
    case browserNavigateFailed = 413
    case browserBackRequested = 414
    case browserForwardRequested = 415
    case browserReloadRequested = 416
    case browserDialogPresented = 417
    case browserDialogResponded = 418
    case browserFrameReceived = 419
    case browserFrameDecodeFailed = 420
    case browserStateReceived = 421
    case browserViewportChanged = 422
    case browserInputFailed = 423
    case browserClosed = 424
    case browserDialogResponseFailed = 425
    case browserStopRequested = 426
    case browserStateDecodeFailed = 427
    case browserDialogDecodeFailed = 428
    case browserClosedDecodeFailed = 429

    // MARK: Settings, feedback, and diagnostics (430-449)
    case settingsOpened = 430
    case settingsClosed = 431
    case feedbackSubmitStarted = 435
    case feedbackSubmitSucceeded = 436
    case feedbackSubmitFailed = 437
    case crashReportingConsentChanged = 438
    case analyticsUploadStarted = 441
    case analyticsUploadSucceeded = 442
    case analyticsUploadFailed = 443
    case analyticsUploadDropped = 444
    case analyticsConsentChanged = 445
    case crashReportingStarted = 446
    case crashReportingDisabled = 447

    // MARK: Camera and media attachments (450-479)
    case cameraAuthorizationRequested = 450
    case cameraAuthorizationGranted = 451
    case cameraAuthorizationDenied = 452
    case qrScanStarted = 453
    case qrScanSucceeded = 454
    case qrScanFailed = 455
    case qrScanCancelled = 456
    case photoPickerOpened = 457
    /// Count is the number of picker results returned.
    case photoPickerSelected = 458
    case photoPickerDismissed = 459
    case attachmentPreparationStarted = 460
    /// Count is the prepared attachment's byte size.
    case attachmentPreparationSucceeded = 461
    case attachmentPreparationFailed = 462

    // MARK: Persistence and capability negotiation (480-519)
    case pairedMacStoreOpened = 480
    case pairedMacStoreOpenFailed = 481
    case pairedMacStoreReadFailed = 482
    case pairedMacStoreWriteFailed = 483
    case draftRestored = 484
    case draftSaved = 485
    case draftPersistenceFailed = 486
    case pairedMacStoreReadSucceeded = 487
    case pairedMacStoreWriteSucceeded = 488
    case pairedMacBackupRefreshStarted = 489
    case pairedMacBackupRefreshSucceeded = 490
    case pairedMacBackupRefreshFailed = 491
    case pairedMacRestoreStarted = 492
    case pairedMacRestoreSucceeded = 493
    case pairedMacRestoreFailed = 494
    case settingPersistenceFailed = 495
    case draftDeleted = 496
    case templatePersistenceFailed = 497
    case pairedMacBackupWriteStarted = 498
    case pairedMacBackupWriteSucceeded = 499
    case capabilitySnapshotReceived = 500
    case pairedMacBackupWriteFailed = 502

    // MARK: Detailed setting mutations (520-559)
    case displayAltScreenNoticeChanged = 520
    case displayFolderTapChanged = 521
    case displayHapticsChanged = 522
    case taskComposerFeatureChanged = 523
    case terminalFilesFeatureChanged = 524
    case toastFeatureChanged = 525
    case displayMissingFilesChanged = 526
    case displayWorkspaceTitleWrappingChanged = 527
    case displayWorkspacePreviewLinesChanged = 528
    case terminalScrollbackRowsChanged = 529
    case telemetrySharingChanged = 530
    /// `c`: ``DiagnosticConnectionMethod`` the user switched to.
    case connectionMethodPreferenceChanged = 531
    /// Detail: ``DiagnosticAppEventDetail/toolbarConfigurationAction(_:)``.
    case customToolbarChanged = 532
    /// Detail: ``DiagnosticAppEventDetail/toolbarConfigurationAction(_:)``.
    case terminalShortcutChanged = 533
    case notificationPreferenceChanged = 534
    case appDiagnosticsShared = 535
    case networkDiagnosticsShared = 536
    case toastPresented = 537
    case toastCoalesced = 538
    case toastQueued = 539
    case toastDropped = 540
    case toastDismissed = 541
    case toastInteractionStarted = 542
    case toastInteractionEnded = 543

    // MARK: Iroh settings (610-639)
    case irohSettingsOpened = 610
    case irohSettingsClosed = 611
    case irohRelayPreferenceChangeStarted = 612
    case irohRelayPreferenceChangeSucceeded = 613
    case irohRelayPreferenceChangeFailed = 614
    case irohPathPreferenceChangeStarted = 615
    case irohPathPreferenceChangeSucceeded = 616
    case irohPathPreferenceChangeFailed = 617
    case irohCustomRelayUpsertStarted = 618
    case irohCustomRelayUpsertSucceeded = 619
    case irohCustomRelayUpsertFailed = 620
    case irohCustomRelayRemoveStarted = 621
    case irohCustomRelayRemoveSucceeded = 622
    case irohCustomRelayRemoveFailed = 623
    case irohCustomRelayTestStarted = 624
    case irohCustomRelayTestSucceeded = 625
    case irohCustomRelayTestFailed = 626
    case irohPrivatePathUpsertStarted = 627
    case irohPrivatePathUpsertSucceeded = 628
    case irohPrivatePathUpsertFailed = 629
    case irohPrivatePathRemoveStarted = 630
    case irohPrivatePathRemoveSucceeded = 631
    case irohPrivatePathRemoveFailed = 632
    case irohDiagnosticsCleared = 633
    case verboseDiagnosticLoggingChanged = 634
    case irohDiagnosticsShared = 635
    case verboseDiagnosticsShared = 636

    // MARK: Terminal composer, media, and feature delivery (640-669)
    case terminalDraftStateChanged = 640
    case terminalAttachmentStaged = 641
    case terminalAttachmentRemoved = 642
    case terminalAttachmentRejected = 643
    case terminalImagePasteStarted = 644
    case terminalImagePasteSucceeded = 645
    case terminalImagePasteFailed = 646
    case terminalViewportClearStarted = 647
    case terminalViewportClearSucceeded = 648
    case terminalViewportClearFailed = 649
    case browserFrameAcknowledgementFailed = 650
    case dictationStartRequested = 651
    case dictationStarted = 652
    case dictationStopRequested = 653
    case dictationStopped = 654
    case dictationCancelled = 655
    case dictationUnavailable = 656
    case dictationFirstResultReceived = 657
    case dictationRecognitionFailed = 658
    case dictationStopTimedOut = 659

    // MARK: Appended persistence events
    case pairedMacStoreWriteStarted = 660

    // MARK: Appended connection reporting events
    /// The configured connection method, recorded at composition and on every
    /// foreground so any shared report window states it even after the ring
    /// rolls past app launch. `c`: ``DiagnosticConnectionMethod``.
    case connectionMethodConfigured = 661
    /// The transport that actually carries the foreground connection, recorded
    /// on connect and on every active-route change. `c`: ``DiagnosticTransportKind``.
    case foregroundTransportSelected = 662
}

/// The user's configured connection method, mirrored from the settings picker
/// without account, address, or grant details.
public enum DiagnosticConnectionMethod: Int, Sendable, Codable, CaseIterable {
    case automatic = 0
    case tailscale = 1
    case direct = 2
}

/// High-level lifecycle state for one phone-controlled Simulator stream.
///
/// Values intentionally omit panel UUIDs, device names, workspace titles, and
/// frame contents. The associated ``DiagnosticEvent`` carries only a
/// process-local surface handle and bounded counters.
public enum DiagnosticSimulatorStreamLifecycle: Int, Sendable, Codable, CaseIterable {
    case startRequested = 1
    case started = 2
    case locked = 3
    case startFailed = 4
    case stopRequested = 5
    case stopped = 6
    case closed = 7
    case restartRequested = 8
    case pausedForBackground = 9
    case descriptorApplied = 10
    /// The client's staleness watchdog saw a full silent interval (no frame
    /// or keepalive) for an active stream and is re-requesting it.
    case stalled = 11
    case stopFailed = 12
}

/// Frame-pipeline state for the Simulator video stream.
public enum DiagnosticSimulatorFrameLifecycle: Int, Sendable, Codable, CaseIterable {
    case readerAttached = 1
    case readerMissing = 2
    case copied = 3
    case encodeFailed = 4
    case sent = 5
    case refused = 6
    case cachedSent = 7
    case subscriptionReasserted = 8
    case received = 9
    case staleIgnored = 10
    case decodeFailed = 11
    case imageDecoded = 12
    case imageDecodeFailed = 13
    case unknownPanel = 14
}

/// Input delivery state for phone-originated Simulator actions.
public enum DiagnosticSimulatorInputLifecycle: Int, Sendable, Codable, CaseIterable {
    case queued = 1
    case sent = 2
    case accepted = 3
    case failed = 4
    case rejectedLocked = 5
    case unavailable = 6
    case invalidParameters = 7
    case panelMissing = 8
    case featureDisabled = 9
    case blockedViewOnly = 10
}

/// Phone-originated Simulator input category.
public enum DiagnosticSimulatorInputKind: Int, Sendable, Codable, CaseIterable {
    case pointer = 1
    case text = 2
    case hardwareButton = 3
}

/// Hardware button category for phone-originated Simulator actions.
public enum DiagnosticSimulatorHardwareButtonKind: Int, Sendable, Codable, CaseIterable {
    case unknown = 0
    case home = 1
    case swipeHome = 2
    case appSwitcher = 3
    case lock = 4
    case siri = 5
    case sideButton = 6
    case power = 7
    case volumeUp = 8
    case volumeDown = 9
    case action = 10
    case watchSideButton = 11
}

/// Pointer phase for phone-originated Simulator touch events.
public enum DiagnosticSimulatorPointerPhase: Int, Sendable, Codable, CaseIterable {
    case began = 1
    case moved = 2
    case ended = 3
    case tap = 4
}

/// Privacy-safe ownership state for a Simulator pane's active controller.
public enum DiagnosticSimulatorOwnershipState: Int, Sendable, Codable, CaseIterable {
    case unowned = 0
    case currentConnection = 1
    case otherConnection = 2
    case pendingHandshake = 3
    case unknown = 4
}

/// Coordinate mapping state for a phone gesture before it leaves the device.
public enum DiagnosticSimulatorCoordinateState: Int, Sendable, Codable, CaseIterable {
    case mapped = 1
    case outsideImage = 2
    case viewOnlyBlocked = 3
    case zeroImage = 4
}
