import AppKit
import CmuxSimulator
import Darwin
import Foundation
import ObjectiveC.runtime

// Adapted from serve-sim's AccessibilityBridge.swift at commit
// af681b8c3b0453f31dcb8e98a3389f23b7cfc6b0 under Apache License 2.0.
// Modified by cmux to use typed bounded messages, worker-only private API
// containment, stricter traversal limits, and correlated native callers.

/// Private accessibility translator bridge confined to the child worker.
///
/// Adapted from idb's accessibility bridge (MIT, Meta Platforms) and
/// serve-sim's Swift port (Apache-2.0, Evan Bacon). The private translator has
/// a synchronous delegate contract, so its one irreducible XPC bridge uses a
/// bounded semaphore wait on a dedicated completion queue. A timeout returns
/// an empty response and lets the host supervisor recover the worker.
final class SimulatorAccessibilityBridge: NSObject, @unchecked Sendable {
    static let maximumNodeCount = 500
    static let maximumDepth = 80
    static let maximumTextUTF8ByteCount = 512

    private let lock = NSLock()
    private let completionQueue = DispatchQueue(
        label: "com.cmux.simulator.accessibility",
        qos: .userInitiated
    )
    private var tokenDevices: [String: NSObject] = [:]
    var translator: NSObject?
    private var attachedDevice: NSObject?

    func attach(device: NSObject) -> Bool {
        lock.withLock {
            attachedDevice = device
        }
        do {
            try loadTranslator()
            return device.responds(
                to: NSSelectorFromString(
                    "sendAccessibilityRequestAsync:completionQueue:completionHandler:"
                )
            )
        } catch {
            return false
        }
    }

    func detach() {
        lock.withLock {
            attachedDevice = nil
            tokenDevices.removeAll()
        }
    }

    func accessibilitySnapshot(
        display: SimulatorDisplayMetadata
    ) throws -> SimulatorAccessibilitySnapshot {
        let (translation, token) = try frontmostTranslation()
        defer { removeToken(token) }
        stampToken(on: translation, token: token)

        let translator = try requireTranslator()
        let selector = NSSelectorFromString("macPlatformElementFromTranslation:")
        guard translator.responds(to: selector),
              let implementation = class_getMethodImplementation(type(of: translator), selector)
        else {
            throw SimulatorWorkerFailure.accessibilityUnavailable(
                "The accessibility translator cannot create a macOS platform element."
            )
        }
        typealias Function = @convention(c) (
            AnyObject,
            Selector,
            AnyObject
        ) -> AnyObject?
        guard let root = unsafeBitCast(implementation, to: Function.self)(
            translator,
            selector,
            translation
        ) as? NSObject else {
            throw SimulatorWorkerFailure.accessibilityUnavailable(
                "The Simulator did not return a frontmost accessibility element."
            )
        }

        stampNestedTranslation(on: root, token: token)
        let rootFrame = (root as? NSAccessibilityElement)?.accessibilityFrame() ?? .zero
        var coverage = SimulatorAccessibilityCoverage()
        var visited: Set<ObjectIdentifier> = []
        var remaining = Self.maximumNodeCount
        var traversalTruncated = false
        var roots = serialize(
            root,
            path: "0",
            token: token,
            depth: 0,
            remaining: &remaining,
            visited: &visited,
            coverage: &coverage,
            traversalTruncated: &traversalTruncated
        ).map { [$0] } ?? []
        roots.append(contentsOf: discoverAccessibilityElements(
            token: token,
            bounds: rootFrame,
            remaining: &remaining,
            visited: &visited,
            coverage: &coverage,
            traversalTruncated: &traversalTruncated
        ))
        return SimulatorAccessibilitySnapshot(
            roots: roots,
            display: display,
            nodeCount: Self.maximumNodeCount - remaining,
            isTruncated: traversalTruncated
        )
    }

    private func loadTranslator() throws {
        if lock.withLock({ translator != nil }) { return }
        let path = "/System/Library/PrivateFrameworks/" +
            "AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation"
        guard dlopen(path, RTLD_NOW | RTLD_GLOBAL) != nil,
              let translatorClass = NSClassFromString("AXPTranslator") as? NSObject.Type
        else {
            throw SimulatorWorkerFailure.accessibilityUnavailable(
                "AccessibilityPlatformTranslation is unavailable."
            )
        }
        let sharedSelector = NSSelectorFromString("sharedInstance")
        guard translatorClass.responds(to: sharedSelector),
              let translator = translatorClass.perform(sharedSelector)?.takeUnretainedValue() as? NSObject
        else {
            throw SimulatorWorkerFailure.accessibilityUnavailable("AXPTranslator is unavailable.")
        }

        guard setObjectProperty(translator, name: "bridgeTokenDelegate", value: self),
              setBoolProperty(translator, name: "supportsDelegateTokens", value: true),
              setBoolProperty(translator, name: "accessibilityEnabled", value: true)
        else {
            throw SimulatorWorkerFailure.accessibilityUnavailable(
                "AXPTranslator does not expose tokenized bridge delegation."
            )
        }
        lock.withLock {
            self.translator = translator
        }
    }

    func frontmostTranslation() throws -> (translation: NSObject, token: String) {
        try loadTranslator()
        let translator = try requireTranslator()
        guard let device = lock.withLock({ attachedDevice }) else {
            throw SimulatorWorkerFailure.accessibilityUnavailable("No Simulator is attached.")
        }
        let token = UUID().uuidString
        lock.withLock {
            tokenDevices[token] = device
        }

        let selector = NSSelectorFromString(
            "frontmostApplicationWithDisplayId:bridgeDelegateToken:"
        )
        guard translator.responds(to: selector),
              let implementation = class_getMethodImplementation(type(of: translator), selector)
        else {
            removeToken(token)
            throw SimulatorWorkerFailure.accessibilityUnavailable(
                "AXPTranslator cannot query the frontmost application."
            )
        }
        typealias Function = @convention(c) (
            AnyObject,
            Selector,
            UInt32,
            NSString
        ) -> AnyObject?
        guard let translation = unsafeBitCast(implementation, to: Function.self)(
            translator,
            selector,
            0,
            token as NSString
        ) as? NSObject else {
            removeToken(token)
            throw SimulatorWorkerFailure.accessibilityUnavailable(
                "The Simulator has no frontmost accessibility application."
            )
        }
        stampToken(on: translation, token: token)
        return (translation, token)
    }

    func requireTranslator() throws -> NSObject {
        guard let translator = lock.withLock({ translator }) else {
            throw SimulatorWorkerFailure.accessibilityUnavailable("AXPTranslator is unavailable.")
        }
        return translator
    }

    func stampToken(on translation: NSObject, token: String) {
        guard !token.isEmpty else { return }
        _ = setObjectProperty(
            translation,
            name: "bridgeDelegateToken",
            value: token as NSString
        )
    }

    func stampNestedTranslation(on element: NSObject, token: String) {
        guard let translation = objectProperty(element, selectorName: "translation") as? NSObject else {
            return
        }
        stampToken(on: translation, token: token)
    }

    func serialize(
        _ object: NSObject,
        path: String,
        token: String,
        depth: Int,
        remaining: inout Int,
        visited: inout Set<ObjectIdentifier>,
        coverage: inout SimulatorAccessibilityCoverage,
        traversalTruncated: inout Bool
    ) -> SimulatorAccessibilityNode? {
        guard depth <= Self.maximumDepth, remaining > 0 else {
            traversalTruncated = true
            return nil
        }
        guard visited.insert(ObjectIdentifier(object)).inserted else {
            return nil
        }
        remaining -= 1
        stampNestedTranslation(on: object, token: token)

        let element = object as? NSAccessibilityElement
        let frame = element?.accessibilityFrame()
        let resolvedFrame = frame ?? .zero
        let rawRole = element?.accessibilityRole()?.rawValue
        let role = rawRole.map { value in
            value.hasPrefix("AX") ? String(value.dropFirst(2)) : value
        }.map(Self.boundedAccessibilityText)
        let label = element?.accessibilityLabel().map(Self.boundedAccessibilityText)
        let rawValue = element?.accessibilityValue()
        let value = rawValue.map { Self.boundedAccessibilityText(String(describing: $0)) }
        let identifier = element?.accessibilityIdentifier().map(Self.boundedAccessibilityText)
        let roleDescription = element?.accessibilityRoleDescription().map(
            Self.boundedAccessibilityText
        )
        let enabled = element?.isAccessibilityEnabled()
        let children = element?.accessibilityChildren() ?? []

        var serializedChildren: [SimulatorAccessibilityNode] = []
        let childLimit = min(children.count, remaining)
        if childLimit < children.count { traversalTruncated = true }
        for (index, child) in children.prefix(childLimit).enumerated() {
            guard remaining > 0 else {
                traversalTruncated = true
                break
            }
            guard let child = child as? NSObject else { continue }
            if let value = serialize(
                child,
                path: "\(path).\(index)",
                token: token,
                depth: depth + 1,
                remaining: &remaining,
                visited: &visited,
                coverage: &coverage,
                traversalTruncated: &traversalTruncated
            ) {
                serializedChildren.append(value)
            }
        }

        if !serializedChildren.isEmpty || Self.isLikelyAccessibilityContainer(resolvedFrame) {
            coverage.insertContainer(resolvedFrame)
        } else {
            coverage.insertLeaf(resolvedFrame)
        }

        let nodeIdentifier = identifier.flatMap { $0.isEmpty ? nil : $0 } ?? path
        return SimulatorAccessibilityNode(
            id: nodeIdentifier,
            role: role,
            label: label,
            value: value,
            roleDescription: roleDescription,
            frame: frame.map {
                SimulatorRect(
                    x: $0.origin.x,
                    y: $0.origin.y,
                    width: $0.size.width,
                    height: $0.size.height
                )
            },
            isEnabled: enabled,
            children: serializedChildren
        )
    }

    private static func isLikelyAccessibilityContainer(_ frame: NSRect) -> Bool {
        max(frame.width, frame.height) >= 250
    }

    static func boundedAccessibilityText(_ value: String) -> String {
        guard value.utf8.count > maximumTextUTF8ByteCount else { return value }
        var result = ""
        var byteCount = 0
        for scalar in value.unicodeScalars {
            let scalarByteCount = scalar.utf8.count
            guard byteCount + scalarByteCount <= maximumTextUTF8ByteCount else { break }
            result.unicodeScalars.append(scalar)
            byteCount += scalarByteCount
        }
        return result
    }

    func removeToken(_ token: String) {
        _ = lock.withLock {
            tokenDevices.removeValue(forKey: token)
        }
    }

    @objc(accessibilityTranslationDelegateBridgeCallbackWithToken:)
    private func bridgeCallback(token: String) -> AnyObject {
        let block: @convention(block) (AnyObject?) -> AnyObject? = { [weak self] request in
            guard let self, let request,
                  let device = self.lock.withLock({ self.tokenDevices[token] })
            else {
                return Self.emptyTranslatorResponse()
            }
            return self.runRequest(request, device: device)
        }
        return block as AnyObject
    }

    private func runRequest(_ request: AnyObject, device: NSObject) -> AnyObject? {
        let selector = NSSelectorFromString(
            "sendAccessibilityRequestAsync:completionQueue:completionHandler:"
        )
        guard device.responds(to: selector),
              let implementation = class_getMethodImplementation(type(of: device), selector)
        else {
            return Self.emptyTranslatorResponse()
        }

        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        let completion: @convention(block) (AnyObject?) -> Void = { response in
            box.value = response
            semaphore.signal()
        }
        typealias Function = @convention(c) (
            AnyObject,
            Selector,
            AnyObject,
            DispatchQueue,
            AnyObject
        ) -> Void
        unsafeBitCast(implementation, to: Function.self)(
            device,
            selector,
            request,
            completionQueue,
            completion as AnyObject
        )
        guard semaphore.wait(timeout: .now() + 3) == .success else {
            return Self.emptyTranslatorResponse()
        }
        return box.value ?? Self.emptyTranslatorResponse()
    }

    @objc(accessibilityTranslationConvertPlatformFrameToSystem:withToken:)
    private func convertFrame(_ rect: NSRect, withToken _: String) -> NSRect {
        rect
    }

    @objc(accessibilityTranslationRootParentWithToken:)
    private func rootParent(withToken _: String) -> AnyObject? {
        nil
    }

    private static func emptyTranslatorResponse() -> AnyObject? {
        guard let responseClass = NSClassFromString("AXPTranslatorResponse") as? NSObject.Type else {
            return nil
        }
        let selector = NSSelectorFromString("emptyResponse")
        guard responseClass.responds(to: selector) else { return nil }
        return responseClass.perform(selector)?.takeUnretainedValue()
    }

}

private final class ResponseBox: @unchecked Sendable {
    var value: AnyObject?
}

private func setObjectProperty(_ target: NSObject, name: String, value: AnyObject) -> Bool {
    let selector = NSSelectorFromString(
        "set\(name.prefix(1).uppercased())\(name.dropFirst()):"
    )
    guard target.responds(to: selector),
          let implementation = class_getMethodImplementation(type(of: target), selector)
    else {
        return false
    }
    typealias Function = @convention(c) (AnyObject, Selector, AnyObject) -> Void
    unsafeBitCast(implementation, to: Function.self)(target, selector, value)
    return true
}

private func setBoolProperty(_ target: NSObject, name: String, value: Bool) -> Bool {
    let selector = NSSelectorFromString(
        "set\(name.prefix(1).uppercased())\(name.dropFirst()):"
    )
    guard target.responds(to: selector),
          let implementation = class_getMethodImplementation(type(of: target), selector)
    else {
        return false
    }
    typealias Function = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
    unsafeBitCast(implementation, to: Function.self)(target, selector, ObjCBool(value))
    return true
}
