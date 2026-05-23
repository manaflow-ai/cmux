import AppKit
import OwlMojoBindingsGenerated
import QuartzCore

@MainActor
final class OwlSurfaceTreePresenter {
    private static var permissionPromptDecisionCache = NativePromptDecisionCache(defaults: .standard)

    struct Actions {
        let devToolsEnabled: Bool
        let acceptPopupMenuItem: (UInt32) -> Void
        let cancelPopup: () -> Void
        let selectFilePickerFiles: ([String]) -> Void
        let cancelFilePicker: () -> Void
        let acceptPermissionPrompt: () -> Void
        let cancelPermissionPrompt: () -> Void
        let submitAuthPrompt: (String, String) -> Void
        let cancelAuthPrompt: () -> Void
        let closeDevTools: () -> Void
    }

    let rootLayer = CALayer()
    private let flippedContentLayer = CALayer()

    private var primaryHostLayer: CALayer?
    private var primaryHostFillsBounds = true
    private var primaryContextID: UInt32 = 0
    private var hostedSurfaceLayers: [UInt64: CALayer] = [:]
    private var hostedSurfaceContextIDs: [UInt64: UInt32] = [:]
    private var hostedSurfaceFrames: [UInt64: CGRect] = [:]
    private var presentedNativeSurfaceIDs = Set<UInt64>()
    private var nativeMenuController: NativeMenuController?
    private var activeFilePickerSurfaceID: UInt64?
    private var activePromptSurfaceID: UInt64?
    private var acknowledgedPromptSurfaceIDs = Set<UInt64>()
    private var statusLayer: CATextLayer?
    private var hostBounds = CGRect.zero
    private var backingScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 1
#if DEBUG
    var suppressesNativePromptSheetsForTesting = false
#endif

    init(fallbackColor: CGColor) {
        rootLayer.anchorPoint = .zero
        rootLayer.position = .zero
        rootLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        rootLayer.backgroundColor = fallbackColor
        rootLayer.masksToBounds = true
        configureHostedLayerGeometry(rootLayer, scale: backingScale)

        flippedContentLayer.isGeometryFlipped = true
        flippedContentLayer.anchorPoint = .zero
        flippedContentLayer.position = .zero
        flippedContentLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        flippedContentLayer.backgroundColor = fallbackColor
        flippedContentLayer.masksToBounds = true
        configureHostedLayerGeometry(flippedContentLayer, scale: backingScale)
        rootLayer.addSublayer(flippedContentLayer)
    }

    var suppressesBrowserCursor: Bool {
        nativeMenuController != nil
    }

    func applyHostGeometry(bounds: CGRect, scale: CGFloat) {
        hostBounds = bounds
        backingScale = max(scale, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let alignedBounds = pixelAlignedBounds()
        rootLayer.frame = alignedBounds
        rootLayer.bounds = CGRect(origin: .zero, size: alignedBounds.size)
        flippedContentLayer.frame = alignedBounds
        flippedContentLayer.bounds = CGRect(origin: .zero, size: alignedBounds.size)
        if let primaryHostLayer, primaryHostFillsBounds {
            applyFrame(alignedBounds, to: primaryHostLayer)
        }
        layoutStatusLayer(in: alignedBounds)
        CATransaction.commit()
    }

    func setPrimaryContextID(_ contextID: UInt32) {
        guard contextID != 0 else {
            return
        }
        if primaryHostLayer == nil {
            guard let layer = try? makeCALayerHost(contextID: contextID, scale: backingScale) else {
                return
            }
            layer.anchorPoint = .zero
            configureRemoteLayerHostResizePolicy(layer)
            applyFrame(pixelAlignedBounds(), to: layer)
            flippedContentLayer.addSublayer(layer)
            primaryHostLayer = layer
        } else if primaryContextID != contextID {
            primaryHostLayer?.setValue(NSNumber(value: contextID), forKey: "contextId")
        }
        primaryContextID = contextID
    }

    func update(surfaceTree: OwlFreshSurfaceTree, hostView: NSView, actions: Actions) {
        let surfaces = surfaceTree.surfaces
            .filter(\.visible)
            .sorted { lhs, rhs in
                if lhs.zIndex != rhs.zIndex {
                    return lhs.zIndex < rhs.zIndex
                }
                return lhs.surfaceId < rhs.surfaceId
            }
        guard let primary = surfaces.first(where: { $0.kind == .webView && $0.contextId != 0 }) ??
            surfaces.first(where: { $0.contextId != 0 }) else {
            presentNativeSurfaces(from: surfaces, hostView: hostView, actions: actions)
            return
        }
        setPrimaryContextID(primary.contextId)
        updatePrimaryHostLayer(with: primary)
        updatePopupLayers(surfaces: surfaces, primary: primary, hostView: hostView)
        presentNativeSurfaces(from: surfaces, hostView: hostView, actions: actions)
    }

    func flush() {
        CATransaction.flush()
        OwlGeometryDebugLogger.record("surfacePresenter.flush", fields: debugGeometryFields(prefix: "presenter"))
    }

    func showStatus(_ message: String?) {
        guard let message, !message.isEmpty else {
            statusLayer?.removeFromSuperlayer()
            statusLayer = nil
            return
        }
        let layer = statusLayer ?? makeStatusLayer()
        layer.string = message
        if layer.superlayer !== flippedContentLayer {
            flippedContentLayer.addSublayer(layer)
        }
        statusLayer = layer
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutStatusLayer(in: pixelAlignedBounds())
        CATransaction.commit()
    }

    func reset() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        primaryHostLayer?.removeFromSuperlayer()
        primaryHostLayer = nil
        primaryHostFillsBounds = true
        primaryContextID = 0
        for layer in hostedSurfaceLayers.values {
            layer.removeFromSuperlayer()
        }
        hostedSurfaceLayers.removeAll()
        hostedSurfaceContextIDs.removeAll()
        hostedSurfaceFrames.removeAll()
        presentedNativeSurfaceIDs.removeAll()
        nativeMenuController = nil
        activeFilePickerSurfaceID = nil
        activePromptSurfaceID = nil
        acknowledgedPromptSurfaceIDs.removeAll()
        statusLayer?.removeFromSuperlayer()
        statusLayer = nil
        CATransaction.commit()
        CATransaction.flush()
    }

    private func makeStatusLayer() -> CATextLayer {
        let layer = CATextLayer()
        layer.contentsScale = backingScale
        layer.alignmentMode = .center
        layer.truncationMode = .end
        layer.fontSize = 13
        layer.foregroundColor = NSColor.white.cgColor
        layer.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        layer.cornerRadius = 6
        layer.masksToBounds = true
        layer.zPosition = 10_000
        return layer
    }

    private func layoutStatusLayer(in bounds: CGRect) {
        guard let statusLayer else {
            return
        }
        statusLayer.contentsScale = backingScale
        let horizontalInset: CGFloat = 16
        let height: CGFloat = 36
        let maxWidth = max(160, bounds.width - horizontalInset * 2)
        let width = min(maxWidth, 360)
        statusLayer.frame = CGRect(
            x: horizontalInset,
            y: max(horizontalInset, bounds.height - height - horizontalInset),
            width: width,
            height: height
        )
    }

    private func updatePrimaryHostLayer(with surface: OwlFreshSurfaceInfo) {
        guard let layer = primaryHostLayer else {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contentsScale = max(CGFloat(surface.scale), 1)
        let alignedBounds = pixelAlignedBounds()
        let targetFrame = primaryHostLayerFrame(for: surface, alignedBounds: alignedBounds)
        primaryHostFillsBounds = framesApproximatelyEqual(targetFrame, alignedBounds)
        configureRemoteLayerHostResizePolicy(layer)
        applyFrame(targetFrame, to: layer)
        layer.zPosition = CGFloat(surface.zIndex)
        CATransaction.commit()
        OwlGeometryDebugLogger.record("surfacePresenter.primaryLayer", fields: [
            "surfaceID": "\(surface.surfaceId)",
            "surfaceKind": "\(surface.kind)",
            "surfaceLabel": surface.label,
            "surfaceFrame": "\(surface.x),\(surface.y),\(surface.width),\(surface.height)",
            "fillBounds": OwlGeometryDebugLogger.bool(primaryHostFillsBounds),
            "targetFrame": OwlGeometryDebugLogger.rect(targetFrame),
            "hostBounds": OwlGeometryDebugLogger.rect(alignedBounds)
        ])
    }

    private func primaryHostLayerFrame(
        for surface: OwlFreshSurfaceInfo,
        alignedBounds: CGRect
    ) -> CGRect {
        if surface.kind == .webView, surface.label == "web-view" {
            return alignedBounds
        }
        let frame = layerFrame(for: surface, origin: .zero)
        return frame.isEmpty ? alignedBounds : frame
    }

#if DEBUG
    var activePromptSurfaceIDForTesting: UInt64? {
        activePromptSurfaceID
    }

    func primaryHostLayerFrameForTesting() -> CGRect? {
        primaryHostLayer?.frame
    }
#endif

    private func updatePopupLayers(
        surfaces: [OwlFreshSurfaceInfo],
        primary: OwlFreshSurfaceInfo,
        hostView: NSView
    ) {
        let renderSurfaces = surfaces.filter { surface in
            surface.contextId != 0 &&
                surface.surfaceId != primary.surfaceId &&
                surface.kind != .nativeMenu &&
                surface.kind != .nativeFilePicker &&
                surface.kind != .nativePermissionPrompt &&
                surface.kind != .nativeAuthPrompt &&
                !isDetachedSurface(surface)
        }
        let activeHostedIDs = Set(renderSurfaces.map(\.surfaceId))
        for staleID in hostedSurfaceLayers.keys where !activeHostedIDs.contains(staleID) {
            hostedSurfaceLayers[staleID]?.removeFromSuperlayer()
            hostedSurfaceLayers[staleID] = nil
            hostedSurfaceContextIDs[staleID] = nil
            hostedSurfaceFrames[staleID] = nil
        }
        for surface in renderSurfaces {
            let presentation = hostedLayerPresentation(for: surface, primary: primary, hostView: hostView)
            let frame = presentation.frame
            let previousContextID = hostedSurfaceContextIDs[surface.surfaceId]
            let previousFrame = hostedSurfaceFrames[surface.surfaceId]
            let shouldRecordPresentation = previousContextID != surface.contextId ||
                previousFrame.map { !framesApproximatelyEqual($0, frame) } ?? true
            let layer = layerForHostedSurface(surface, parentLayer: presentation.parentLayer)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contentsScale = max(CGFloat(surface.scale), 1)
            layer.frame = frame
            layer.bounds = CGRect(origin: .zero, size: frame.size)
            layer.position = frame.origin
            layer.zPosition = CGFloat(surface.zIndex)
            layer.borderWidth = 0
            CATransaction.commit()
            hostedSurfaceFrames[surface.surfaceId] = frame
            if shouldRecordPresentation {
                var fields: [String: Any] = [
                    "layerFrameX": frame.origin.x,
                    "layerFrameY": frame.origin.y,
                    "layerFrameWidth": frame.width,
                    "layerFrameHeight": frame.height,
                    "layerZPosition": surface.zIndex
                ]
                fields.merge(presentation.auditFields) { current, _ in current }
                OwlInputEventAuditLogger.recordHostedSurface(
                    name: "hostedSurface.present",
                    surface: surface,
                    host: hostView,
                    extraFields: fields
                )
            }
        }
    }

    private func hostedLayerPresentation(
        for surface: OwlFreshSurfaceInfo,
        primary: OwlFreshSurfaceInfo,
        hostView: NSView
    ) -> HostedLayerPresentation {
        if surface.kind == .popupWidget {
            return HostedLayerPresentation(
                frame: hostedLayerFrame(for: surface, origin: .zero),
                parentLayer: flippedContentLayer,
                auditFields: hostFrameFields(for: hostView)
                    .merging(["layerCoordinateSpace": "web-content-host"]) { current, _ in current }
            )
        }
        let origin = surface.kind == .webView ? CGPoint(x: CGFloat(primary.x), y: CGFloat(primary.y)) : .zero
        return HostedLayerPresentation(
            frame: hostedLayerFrame(for: surface, origin: origin),
            parentLayer: flippedContentLayer,
            auditFields: hostFrameFields(for: hostView).merging(["layerCoordinateSpace": "web-content-host"]) { current, _ in current }
        )
    }

    private func layerForHostedSurface(_ surface: OwlFreshSurfaceInfo, parentLayer: CALayer) -> CALayer {
        if let existing = hostedSurfaceLayers[surface.surfaceId] {
            if hostedSurfaceContextIDs[surface.surfaceId] != surface.contextId {
                hostedSurfaceContextIDs[surface.surfaceId] = surface.contextId
                existing.setValue(NSNumber(value: surface.contextId), forKey: "contextId")
            }
            if existing.superlayer !== parentLayer {
                parentLayer.addSublayer(existing)
            }
            return existing
        }
        let layer = (try? makeCALayerHost(contextID: surface.contextId, scale: backingScale)) ?? CALayer()
        layer.anchorPoint = .zero
        configureHostedLayerGeometry(layer, scale: backingScale)
        parentLayer.addSublayer(layer)
        hostedSurfaceLayers[surface.surfaceId] = layer
        hostedSurfaceContextIDs[surface.surfaceId] = surface.contextId
        return layer
    }

    private func presentNativeSurfaces(from surfaces: [OwlFreshSurfaceInfo], hostView: NSView, actions: Actions) {
        let visiblePromptSurfaceIDs = Set(surfaces.compactMap { surface -> UInt64? in
            switch surface.kind {
            case .nativePermissionPrompt, .nativeAuthPrompt:
                return surface.surfaceId
            default:
                return nil
            }
        })
        acknowledgedPromptSurfaceIDs = acknowledgedPromptSurfaceIDs.intersection(visiblePromptSurfaceIDs)

        for surface in surfaces where surface.kind == .nativeMenu && !presentedNativeSurfaceIDs.contains(surface.surfaceId) {
            presentedNativeSurfaceIDs.insert(surface.surfaceId)
            presentNativeMenu(surface, hostView: hostView, actions: actions)
        }
        for surface in surfaces where surface.kind == .nativeFilePicker && activeFilePickerSurfaceID != surface.surfaceId {
            activeFilePickerSurfaceID = surface.surfaceId
            presentFilePicker(surface, hostView: hostView, actions: actions)
        }
        for surface in surfaces where surface.kind == .nativePermissionPrompt &&
            !acknowledgedPromptSurfaceIDs.contains(surface.surfaceId) {
            guard activePromptSurfaceID == nil else {
                continue
            }
            activePromptSurfaceID = surface.surfaceId
            presentPermissionPrompt(surface, hostView: hostView, actions: actions)
        }
        for surface in surfaces where surface.kind == .nativeAuthPrompt &&
            !acknowledgedPromptSurfaceIDs.contains(surface.surfaceId) {
            guard activePromptSurfaceID == nil else {
                continue
            }
            activePromptSurfaceID = surface.surfaceId
            presentAuthPrompt(surface, hostView: hostView, actions: actions)
        }
    }

    private func presentNativeMenu(_ surface: OwlFreshSurfaceInfo, hostView: NSView, actions: Actions) {
        OwlInputEventAuditLogger.recordNativeSurface(
            name: "nativeMenu.present.request",
            surface: surface,
            host: hostView
        )
        let controller = NativeMenuController(surface: surface, devToolsEnabled: actions.devToolsEnabled) { [weak self] result in
            guard let self else {
                return
            }
            self.nativeMenuController = nil
            self.presentedNativeSurfaceIDs.remove(surface.surfaceId)
            switch result {
            case .selected(let index):
                actions.acceptPopupMenuItem(UInt32(index))
            case .cancelled:
                actions.cancelPopup()
            }
        }
        nativeMenuController = controller
        let rect = topLeftSurfaceRect(for: surface, origin: .zero)
        let point = CGPoint(x: max(rect.minX, 0), y: max(hostBounds.height - rect.maxY, 0))
        controller.present(surface: surface, at: point, in: hostView)
    }

    private func presentFilePicker(_ surface: OwlFreshSurfaceInfo, hostView: NSView, actions: Actions) {
        OwlInputEventAuditLogger.recordNativeSurface(
            name: "nativeFilePicker.present.request",
            surface: surface,
            host: hostView,
            extraFields: [
                "filePickerMode": surface.filePickerMode,
                "filePickerAcceptTypes": surface.filePickerAcceptTypes,
                "filePickerAllowsMultiple": surface.filePickerAllowsMultiple,
                "filePickerUploadFolder": surface.filePickerUploadFolder
            ]
        )
        guard let window = hostView.window else {
            OwlInputEventAuditLogger.recordNativeSurface(
                name: "nativeFilePicker.present.noWindow",
                surface: surface,
                host: hostView
            )
            actions.cancelFilePicker()
            return
        }
        let panel = NSOpenPanel()
        NativeFilePickerPanelConfiguration(surface: surface).apply(to: panel)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else {
                return
            }
            self.activeFilePickerSurfaceID = nil
            if response == .OK {
                OwlInputEventAuditLogger.recordNativeSurface(
                    name: "nativeFilePicker.present.response",
                    surface: surface,
                    host: hostView,
                    extraFields: [
                        "accepted": true,
                        "selectedPathCount": panel.urls.count
                    ]
                )
                actions.selectFilePickerFiles(panel.urls.map(\.path))
            } else {
                OwlInputEventAuditLogger.recordNativeSurface(
                    name: "nativeFilePicker.present.response",
                    surface: surface,
                    host: hostView,
                    extraFields: [
                        "accepted": false,
                        "selectedPathCount": 0
                    ]
                )
                actions.cancelFilePicker()
            }
        }
    }

    private func presentPermissionPrompt(_ surface: OwlFreshSurfaceInfo, hostView: NSView, actions: Actions) {
        let config = nativePromptConfiguration(surface: surface)
        let fingerprint = NativePromptFingerprint(surface: surface, configuration: config)
        OwlInputEventAuditLogger.recordNativeSurface(
            name: "nativePermissionPrompt.present.request",
            surface: surface,
            host: hostView,
            extraFields: promptAuditFields(surface)
        )
        if let cachedDecision = Self.permissionPromptDecisionCache.decision(for: fingerprint) {
            acknowledgedPromptSurfaceIDs.insert(surface.surfaceId)
            activePromptSurfaceID = nil
            OwlInputEventAuditLogger.recordNativeSurface(
                name: "nativePermissionPrompt.present.cachedDecision",
                surface: surface,
                host: hostView,
                extraFields: promptAuditFields(surface).merging([
                    "accepted": cachedDecision == .accept
                ]) { current, _ in current }
            )
            switch cachedDecision {
            case .accept:
                actions.acceptPermissionPrompt()
            case .cancel:
                actions.cancelPermissionPrompt()
            }
            return
        }
#if DEBUG
        if suppressesNativePromptSheetsForTesting {
            return
        }
#endif
        guard let window = hostView.window else {
            OwlInputEventAuditLogger.recordNativeSurface(
                name: "nativePermissionPrompt.present.noWindow",
                surface: surface,
                host: hostView,
                extraFields: promptAuditFields(surface)
            )
            acknowledgedPromptSurfaceIDs.insert(surface.surfaceId)
            activePromptSurfaceID = nil
            actions.cancelPermissionPrompt()
            return
        }
        let alert = makeNativePermissionPromptAlert(configuration: config)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else {
                return
            }
            self.acknowledgedPromptSurfaceIDs.insert(surface.surfaceId)
            self.activePromptSurfaceID = nil
            let accepted = response == .alertFirstButtonReturn
            Self.permissionPromptDecisionCache.remember(
                accepted ? .accept : .cancel,
                for: fingerprint
            )
            OwlInputEventAuditLogger.recordNativeSurface(
                name: "nativePermissionPrompt.present.response",
                surface: surface,
                host: hostView,
                extraFields: promptAuditFields(surface).merging(["accepted": accepted]) { current, _ in current }
            )
            if accepted {
                actions.acceptPermissionPrompt()
            } else {
                actions.cancelPermissionPrompt()
            }
        }
    }

    private func presentAuthPrompt(_ surface: OwlFreshSurfaceInfo, hostView: NSView, actions: Actions) {
        OwlInputEventAuditLogger.recordNativeSurface(
            name: "nativeAuthPrompt.present.request",
            surface: surface,
            host: hostView,
            extraFields: promptAuditFields(surface)
        )
#if DEBUG
        if suppressesNativePromptSheetsForTesting {
            return
        }
#endif
        guard let window = hostView.window else {
            OwlInputEventAuditLogger.recordNativeSurface(
                name: "nativeAuthPrompt.present.noWindow",
                surface: surface,
                host: hostView,
                extraFields: promptAuditFields(surface)
            )
            acknowledgedPromptSurfaceIDs.insert(surface.surfaceId)
            activePromptSurfaceID = nil
            actions.cancelAuthPrompt()
            return
        }
        let prompt = makeNativeAuthPromptAlert(surface: surface)
        prompt.alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else {
                return
            }
            self.acknowledgedPromptSurfaceIDs.insert(surface.surfaceId)
            self.activePromptSurfaceID = nil
            let accepted = response == .alertFirstButtonReturn
            OwlInputEventAuditLogger.recordNativeSurface(
                name: "nativeAuthPrompt.present.response",
                surface: surface,
                host: hostView,
                extraFields: promptAuditFields(surface).merging([
                    "accepted": accepted,
                    "usernameSupplied": !prompt.usernameField.stringValue.isEmpty,
                    "passwordSupplied": !prompt.passwordField.stringValue.isEmpty
                ]) { current, _ in current }
            )
            if accepted {
                actions.submitAuthPrompt(prompt.usernameField.stringValue, prompt.passwordField.stringValue)
            } else {
                actions.cancelAuthPrompt()
            }
        }
    }

    private func topLeftSurfaceRect(for surface: OwlFreshSurfaceInfo, origin: CGPoint) -> CGRect {
        CGRect(
            x: CGFloat(surface.x) - origin.x,
            y: CGFloat(surface.y) - origin.y,
            width: CGFloat(surface.width),
            height: CGFloat(surface.height)
        )
    }

    private func layerFrame(for surface: OwlFreshSurfaceInfo, origin: CGPoint) -> CGRect {
        let rect = topLeftSurfaceRect(for: surface, origin: origin)
        return CGRect(
            x: rect.origin.x,
            y: max(hostBounds.height - rect.maxY, 0),
            width: rect.width,
            height: rect.height
        )
    }

    private func hostedLayerFrame(for surface: OwlFreshSurfaceInfo, origin: CGPoint) -> CGRect {
        let rect = topLeftSurfaceRect(for: surface, origin: origin)
        if surface.kind == .popupWidget {
            return rect
        }
        return CGRect(
            x: rect.origin.x,
            y: max(hostBounds.height - rect.maxY, 0),
            width: rect.width,
            height: rect.height
        )
    }

    private func applyFrame(_ frame: CGRect, to layer: CALayer) {
        let alignedFrame = pixelAligned(frame)
        layer.frame = alignedFrame
        layer.bounds = CGRect(origin: .zero, size: alignedFrame.size)
        layer.position = alignedFrame.origin
    }

    func debugGeometryFields(prefix: String) -> [String: String] {
        var fields: [String: String] = [
            "\(prefix).hostBounds": OwlGeometryDebugLogger.rect(hostBounds),
            "\(prefix).rootFrame": OwlGeometryDebugLogger.rect(rootLayer.frame),
            "\(prefix).rootBounds": OwlGeometryDebugLogger.rect(rootLayer.bounds),
            "\(prefix).flippedFrame": OwlGeometryDebugLogger.rect(flippedContentLayer.frame),
            "\(prefix).flippedBounds": OwlGeometryDebugLogger.rect(flippedContentLayer.bounds),
            "\(prefix).scale": String(format: "%.3f", backingScale),
            "\(prefix).primaryFillsBounds": OwlGeometryDebugLogger.bool(primaryHostFillsBounds),
            "\(prefix).primaryContextID": "\(primaryContextID)",
            "\(prefix).hostedSurfaceCount": "\(hostedSurfaceLayers.count)"
        ]
        if let primaryHostLayer {
            fields["\(prefix).primaryFrame"] = OwlGeometryDebugLogger.rect(primaryHostLayer.frame)
            fields["\(prefix).primaryBounds"] = OwlGeometryDebugLogger.rect(primaryHostLayer.bounds)
        } else {
            fields["\(prefix).primaryFrame"] = "nil"
            fields["\(prefix).primaryBounds"] = "nil"
        }
        return fields
    }

    private func pixelAlignedBounds() -> CGRect {
        pixelAligned(CGRect(origin: .zero, size: hostBounds.size))
    }

    private func pixelAligned(_ rect: CGRect) -> CGRect {
        CGRect(
            x: (rect.origin.x * backingScale).rounded() / backingScale,
            y: (rect.origin.y * backingScale).rounded() / backingScale,
            width: (rect.size.width * backingScale).rounded() / backingScale,
            height: (rect.size.height * backingScale).rounded() / backingScale
        )
    }

    private func isDetachedSurface(_ surface: OwlFreshSurfaceInfo) -> Bool {
        surface.kind == .devTools && surface.label == "devtools-window"
    }

    func hostedSurfaceFrameForTesting(surfaceID: UInt64) -> CGRect? {
        hostedSurfaceFrames[surfaceID]
    }
}

@MainActor
private func hostFrameFields(for hostView: NSView) -> [String: Any] {
    guard let window = hostView.window else {
        return [:]
    }
    let frameInWindow = hostView.convert(hostView.bounds, to: nil)
    return [
        "hostFrameInWindowX": frameInWindow.origin.x,
        "hostFrameInWindowY": frameInWindow.origin.y,
        "hostFrameInWindowWidth": frameInWindow.width,
        "hostFrameInWindowHeight": frameInWindow.height,
        "hostTopLeftInWindowX": frameInWindow.minX,
        "hostTopLeftInWindowY": max(window.frame.height - frameInWindow.maxY, 0)
    ]
}

private func framesApproximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    abs(lhs.origin.x - rhs.origin.x) < 0.25 &&
        abs(lhs.origin.y - rhs.origin.y) < 0.25 &&
        abs(lhs.size.width - rhs.size.width) < 0.25 &&
        abs(lhs.size.height - rhs.size.height) < 0.25
}

private struct HostedLayerPresentation {
    let frame: CGRect
    let parentLayer: CALayer
    let auditFields: [String: Any]
}

struct OwlNativePromptConfiguration: Equatable {
    let title: String
    let message: String
    let primaryButton: String
    let secondaryButton: String
    let defaultUsername: String
    let origin: String
    let requiresCredentials: Bool
}

@MainActor
func owlNativePromptConfigurationForTesting(surface: OwlFreshSurfaceInfo) -> OwlNativePromptConfiguration {
    nativePromptConfiguration(surface: surface)
}

@MainActor
private func makeNativePermissionPromptAlert(configuration config: OwlNativePromptConfiguration) -> NSAlert {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = config.title
    alert.informativeText = config.message
    alert.addButton(withTitle: config.primaryButton)
    alert.addButton(withTitle: config.secondaryButton)
    return alert
}

@MainActor
private func makeNativeAuthPromptAlert(surface: OwlFreshSurfaceInfo) -> NativeAuthPromptAlert {
    let config = nativePromptConfiguration(surface: surface)
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = config.title
    alert.informativeText = config.message
    alert.addButton(withTitle: config.primaryButton)
    alert.addButton(withTitle: config.secondaryButton)

    let usernameField = NSTextField(string: config.defaultUsername)
    usernameField.placeholderString = L10n.string("nativePrompt.username.placeholder", defaultValue: "Username")
    let passwordField = NSSecureTextField(frame: .zero)
    passwordField.stringValue = ""
    passwordField.placeholderString = L10n.string("nativePrompt.password.placeholder", defaultValue: "Password")

    let stack = NSStackView()
    stack.orientation = .vertical
    stack.spacing = 8
    stack.alignment = .leading
    stack.addArrangedSubview(usernameField)
    stack.addArrangedSubview(passwordField)
    usernameField.widthAnchor.constraint(equalToConstant: 280).isActive = true
    passwordField.widthAnchor.constraint(equalToConstant: 280).isActive = true
    stack.frame = CGRect(x: 0, y: 0, width: 280, height: 58)
    alert.accessoryView = stack
    alert.window.initialFirstResponder = usernameField
    return NativeAuthPromptAlert(alert: alert, usernameField: usernameField, passwordField: passwordField)
}

@MainActor
private func nativePromptConfiguration(surface: OwlFreshSurfaceInfo) -> OwlNativePromptConfiguration {
    let isAuth = surface.kind == .nativeAuthPrompt
    let titleFallback = isAuth
        ? L10n.string("nativePrompt.auth.title", defaultValue: "Authentication Required")
        : L10n.string("nativePrompt.permission.title", defaultValue: "Permission Request")
    let messageFallback = isAuth
        ? L10n.string("nativePrompt.auth.message", defaultValue: "Enter credentials for this site.")
        : L10n.string("nativePrompt.permission.message", defaultValue: "This site is requesting permission.")
    let primaryFallback = isAuth
        ? L10n.string("nativePrompt.auth.primary", defaultValue: "Sign In")
        : L10n.string("nativePrompt.permission.primary", defaultValue: "Allow")
    let secondaryFallback = isAuth
        ? L10n.string("nativePrompt.auth.secondary", defaultValue: "Cancel")
        : L10n.string("nativePrompt.permission.secondary", defaultValue: "Deny")
    return OwlNativePromptConfiguration(
        title: surface.promptTitle.isEmpty ? titleFallback : surface.promptTitle,
        message: surface.promptMessage.isEmpty ? messageFallback : surface.promptMessage,
        primaryButton: surface.promptPrimaryButton.isEmpty ? primaryFallback : surface.promptPrimaryButton,
        secondaryButton: surface.promptSecondaryButton.isEmpty ? secondaryFallback : surface.promptSecondaryButton,
        defaultUsername: surface.promptDefaultUsername,
        origin: surface.promptOrigin,
        requiresCredentials: isAuth
    )
}

private func promptAuditFields(_ surface: OwlFreshSurfaceInfo) -> [String: Any] {
    [
        "promptTitle": surface.promptTitle,
        "promptMessage": surface.promptMessage,
        "promptPrimaryButton": surface.promptPrimaryButton,
        "promptSecondaryButton": surface.promptSecondaryButton,
        "promptDefaultUsernameSupplied": !surface.promptDefaultUsername.isEmpty,
        "promptOrigin": surface.promptOrigin
    ]
}

enum NativePromptDecision: String, Equatable {
    case accept
    case cancel
}

struct NativePromptFingerprint: Hashable {
    let kindRawValue: UInt32
    let permissionKey: String
    let origin: String

    init(surface: OwlFreshSurfaceInfo, configuration: OwlNativePromptConfiguration) {
        self.kindRawValue = surface.kind.rawValue
        self.permissionKey = Self.permissionKey(for: configuration.message)
        self.origin = Self.normalizedOrigin(configuration.origin, message: configuration.message)
    }

    var persistedKeyComponent: String {
        let rawValue = "\(kindRawValue)|\(origin)|\(permissionKey)"
        return Data(rawValue.utf8).base64EncodedString()
    }

    private static func normalizedOrigin(_ origin: String, message: String) -> String {
        let candidate = origin.isEmpty ? originFromPromptMessage(message) : origin
        guard let url = URL(string: candidate), let host = url.host?.lowercased() else {
            return normalizedPromptToken(candidate)
        }
        let scheme = url.scheme?.lowercased() ?? "https"
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    private static func originFromPromptMessage(_ message: String) -> String {
        guard let range = message.range(of: " wants to use ", options: [.caseInsensitive]) else {
            return ""
        }
        return String(message[..<range.lowerBound])
    }

    private static func permissionKey(for message: String) -> String {
        let normalizedMessage = normalizedPromptToken(message)
        if normalizedMessage.contains("geolocation") ||
            normalizedMessage.contains("location") {
            return "geolocation"
        }
        if normalizedMessage.contains("notification") {
            return "notifications"
        }
        if normalizedMessage.contains("camera") ||
            normalizedMessage.contains("video capture") ||
            normalizedMessage.contains("videocapture") {
            return "camera"
        }
        if normalizedMessage.contains("microphone") ||
            normalizedMessage.contains("audio capture") ||
            normalizedMessage.contains("audiocapture") {
            return "microphone"
        }
        guard let range = message.range(of: " wants to use ", options: [.caseInsensitive]) else {
            return normalizedMessage
        }
        let permissionText = message[range.upperBound...]
            .trimmingCharacters(in: CharacterSet(charactersIn: ". \n\t"))
        let permissions = permissionText
            .split(separator: ",")
            .map { normalizedPromptToken(String($0)) }
            .filter { !$0.isEmpty }
            .sorted()
        return permissions.isEmpty ? normalizedPromptToken(message) : permissions.joined(separator: ",")
    }

    private static func normalizedPromptToken(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
    }
}

struct NativePromptDecisionCache {
    private static let defaultsKeyPrefix = "owl.nativePromptDecision."

    private var decisions: [NativePromptFingerprint: NativePromptDecision] = [:]
    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
    }

    func decision(for fingerprint: NativePromptFingerprint) -> NativePromptDecision? {
        if let decision = decisions[fingerprint] {
            return decision
        }
        guard let rawValue = defaults?.string(forKey: defaultsKey(for: fingerprint)) else {
            return nil
        }
        return NativePromptDecision(rawValue: rawValue)
    }

    mutating func remember(_ decision: NativePromptDecision, for fingerprint: NativePromptFingerprint) {
        decisions[fingerprint] = decision
        defaults?.set(decision.rawValue, forKey: defaultsKey(for: fingerprint))
    }

    mutating func removeAll() {
        decisions.removeAll()
        guard let defaults else {
            return
        }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.defaultsKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private func defaultsKey(for fingerprint: NativePromptFingerprint) -> String {
        Self.defaultsKeyPrefix + fingerprint.persistedKeyComponent
    }
}

private struct NativeAuthPromptAlert {
    let alert: NSAlert
    let usernameField: NSTextField
    let passwordField: NSSecureTextField
}

private enum NativeMenuResult {
    case selected(Int)
    case cancelled
}

@MainActor
private final class NativeMenuController: NSObject, NSMenuDelegate {
    enum PresentationStyle: Equatable {
        case popup
        case contextMenu
    }

    let menu: NSMenu
    let presentationStyle: PresentationStyle
    private let devToolsEnabled: Bool
    private let onResult: (NativeMenuResult) -> Void
    private var selected = false
    private var resultDelivered = false
    private var registeredOpen = false
    private var currentSurface: OwlFreshSurfaceInfo?
    private weak var currentHostView: NSView?

    init(
        surface: OwlFreshSurfaceInfo,
        devToolsEnabled: Bool = true,
        onResult: @escaping (NativeMenuResult) -> Void
    ) {
        self.menu = NSMenu(title: surface.label)
        self.presentationStyle = surface.label == "context-menu" ? .contextMenu : .popup
        self.devToolsEnabled = devToolsEnabled
        self.onResult = onResult
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        if surface.nativeMenuItems.isEmpty {
            addLegacyMenuItems(surface.menuItems)
        } else {
            addNativeMenuItems(surface.nativeMenuItems)
        }
    }

    private func addLegacyMenuItems(_ labels: [String]) {
        for (index, label) in labels.enumerated() {
            if label == "---" {
                menu.addItem(.separator())
                continue
            }
            guard shouldIncludeMenuItem(label: label, toolTip: "") else {
                continue
            }
            menu.addItem(makeMenuItem(label: label, index: index, enabled: true, toolTip: ""))
        }
    }

    private func addNativeMenuItems(_ items: [OwlFreshNativeMenuItem]) {
        for (index, item) in items.enumerated() {
            if item.separator {
                menu.addItem(.separator())
                continue
            }
            guard shouldIncludeMenuItem(label: item.label, toolTip: item.toolTip) else {
                continue
            }
            menu.addItem(makeMenuItem(
                label: item.label,
                index: index,
                enabled: item.enabled,
                toolTip: item.toolTip
            ))
        }
    }

    private func makeMenuItem(label: String, index: Int, enabled: Bool, toolTip: String) -> NSMenuItem {
        let item = NSMenuItem(
            title: label.isEmpty ? " " : label,
            action: #selector(selectItem(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.tag = index
        item.isEnabled = enabled
        if !toolTip.isEmpty {
            item.toolTip = toolTip
        }
        return item
    }

    private func shouldIncludeMenuItem(label: String, toolTip: String) -> Bool {
        guard presentationStyle == .contextMenu, !devToolsEnabled else {
            return true
        }
        let token = "\(label) \(toolTip)".lowercased()
        return !token.contains("inspect") &&
            !token.contains("developer tools") &&
            !token.contains("devtools")
    }

    func present(surface: OwlFreshSurfaceInfo, at point: CGPoint, in hostView: NSView) {
        currentSurface = surface
        currentHostView = hostView
        switch presentationStyle {
        case .contextMenu:
            presentContextMenu(surface: surface, at: point, in: hostView)
        case .popup:
            BrowserNativeSurfaceTracker.menuDidOpen()
            registeredOpen = true
            OwlInputEventAuditLogger.recordNativeSurface(
                name: "nativeMenu.present.popup",
                surface: surface,
                host: hostView,
                extraFields: [
                    "presentationX": point.x,
                    "presentationY": point.y
                ]
            )
            let opened = menu.popUp(positioning: nil, at: point, in: hostView)
            OwlInputEventAuditLogger.recordNativeSurface(
                name: "nativeMenu.present.popupReturn",
                surface: surface,
                host: hostView,
                extraFields: ["opened": opened]
            )
            if !opened {
                complete(.cancelled)
            } else if !resultDelivered {
                complete(.cancelled)
            }
        }
    }

    private func presentContextMenu(surface: OwlFreshSurfaceInfo, at point: CGPoint, in hostView: NSView) {
        guard let window = hostView.window else {
            OwlInputEventAuditLogger.recordNativeSurface(
                name: "nativeMenu.present.contextNoWindow",
                surface: surface,
                host: hostView
            )
            onResult(.cancelled)
            return
        }
        BrowserNativeSurfaceTracker.menuDidOpen()
        registeredOpen = true
        OwlInputEventAuditLogger.recordNativeSurface(
            name: "nativeMenu.present.context",
            surface: surface,
            host: hostView,
            extraFields: [
                "presentationX": point.x,
                "presentationY": point.y,
                "eventWindowNumber": window.windowNumber
            ]
        )
        guard let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: hostView.convert(point, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
            OwlInputEventAuditLogger.recordNativeSurface(
                name: "nativeMenu.present.contextNoEvent",
                surface: surface,
                host: hostView
            )
            complete(.cancelled)
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: hostView)
        OwlInputEventAuditLogger.recordNativeSurface(
            name: "nativeMenu.present.contextReturn",
            surface: surface,
            host: hostView
        )
        if !resultDelivered {
            complete(.cancelled)
        }
    }

    @objc private func selectItem(_ sender: NSMenuItem) {
        selected = true
        if let currentSurface, let currentHostView {
            OwlInputEventAuditLogger.recordNativeSurface(
                name: "nativeMenu.select",
                surface: currentSurface,
                host: currentHostView,
                extraFields: [
                    "selectedIndex": sender.tag,
                    "selectedTitle": sender.title
                ]
            )
        }
        complete(.selected(sender.tag))
    }

    func menuDidClose(_ menu: NSMenu) {
        if let currentSurface, let currentHostView {
            OwlInputEventAuditLogger.recordNativeSurface(
                name: "nativeMenu.close",
                surface: currentSurface,
                host: currentHostView,
                extraFields: ["selected": selected]
            )
        }
        markClosedIfNeeded()
    }

    private func markClosedIfNeeded() {
        guard registeredOpen else {
            return
        }
        registeredOpen = false
        BrowserNativeSurfaceTracker.menuDidClose(closingEvent: NSApp?.currentEvent)
    }

    private func complete(_ result: NativeMenuResult) {
        guard !resultDelivered else {
            return
        }
        resultDelivered = true
        markClosedIfNeeded()
        onResult(result)
    }
}

@MainActor
func makeOwlNativeMenuForTesting(surface: OwlFreshSurfaceInfo) -> NSMenu {
    NativeMenuController(surface: surface) { _ in }.menu
}

@MainActor
func owlNativeMenuPresentationStyleForTesting(surface: OwlFreshSurfaceInfo) -> String {
    let controller = NativeMenuController(surface: surface, onResult: { _ in })
    switch controller.presentationStyle {
    case .contextMenu:
        return "contextMenu"
    case .popup:
        return "popup"
    }
}

@MainActor
func owlNativeMenuResultsForCloseBeforeSelectTesting(surface: OwlFreshSurfaceInfo, selectedIndex: Int) -> [String] {
    var results: [String] = []
    let controller = NativeMenuController(surface: surface) { result in
        switch result {
        case .selected(let index):
            results.append("selected:\(index)")
        case .cancelled:
            results.append("cancelled")
        }
    }
    controller.menuDidClose(controller.menu)
    guard let item = controller.menu.items.first(where: { $0.tag == selectedIndex }),
          let action = item.action else {
        return results
    }
    _ = (item.target as AnyObject).perform(action, with: item)
    return results
}

private func makeCALayerHost(contextID: UInt32, scale: CGFloat) throws -> CALayer {
    guard let layerClass = NSClassFromString("CALayerHost") as? NSObject.Type else {
        throw LayerHostError.unavailable
    }
    guard let layer = layerClass.init() as? CALayer else {
        throw LayerHostError.invalidInstance
    }
    layer.contentsScale = max(scale, 1)
    layer.setValue(NSNumber(value: contextID), forKey: "contextId")
    layer.setValue(true, forKey: "inheritsSecurity")
    configureHostedLayerGeometry(layer, scale: scale)
    return layer
}

private func configureHostedLayerGeometry(_ layer: CALayer, scale: CGFloat) {
    layer.contentsScale = max(scale, 1)
    layer.anchorPoint = .zero
    layer.masksToBounds = true
    layer.allowsEdgeAntialiasing = false
    layer.edgeAntialiasingMask = []
    layer.contentsGravity = .topLeft
    layer.minificationFilter = .nearest
    layer.magnificationFilter = .nearest
}

private func configureRemoteLayerHostResizePolicy(_ layer: CALayer) {
    // Chromium's DisplayCALayerTree pins CALayerHost to the top-left and lets
    // its parent resize. Matching that avoids AppKit adjusting the hosted
    // remote layer vertically during live window resize.
    layer.autoresizingMask = [.layerMaxXMargin, .layerMaxYMargin]
}

private enum LayerHostError: Error {
    case unavailable
    case invalidInstance
}
