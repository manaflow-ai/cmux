import AppKit
import CMUXMobileCore
import CoreGraphics
import Foundation
import WebKit

@MainActor
struct MobileBrowserInputReplayer {
    func replayPointer(_ input: MobileBrowserPointerInput, in webView: WKWebView) throws {
        let location = try locationInWindow(x: input.x, y: input.y, webView: webView)
        let clickCount = max(1, input.clickCount)
        switch input.kind {
        case .click:
            try deliverMouse(type: mouseDownType(for: input.button), button: input.button, location: location, clickCount: clickCount, webView: webView)
            try deliverMouse(type: mouseUpType(for: input.button), button: input.button, location: location, clickCount: clickCount, webView: webView)
        case .down:
            try deliverMouse(type: mouseDownType(for: input.button), button: input.button, location: location, clickCount: clickCount, webView: webView)
        case .up:
            try deliverMouse(type: mouseUpType(for: input.button), button: input.button, location: location, clickCount: clickCount, webView: webView)
        }
    }

    func replayScroll(_ input: MobileBrowserScrollInput, in webView: WKWebView) throws {
        guard input.deltaX.isFinite, input.deltaY.isFinite else {
            throw MobileBrowserInputReplayError.invalidCoordinates
        }
        let location = try locationInWindow(x: input.x, y: input.y, webView: webView)
        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(clamping: Int(input.deltaY.rounded())),
            wheel2: Int32(clamping: Int(input.deltaX.rounded())),
            wheel3: 0
        ) else {
            throw MobileBrowserInputReplayError.eventCreationFailed
        }
        cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cgEvent.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: input.deltaY)
        cgEvent.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: input.deltaX)
        applyScrollPhase(input.phase, to: cgEvent)
        if let window = webView.window {
            cgEvent.location = window.convertPoint(toScreen: location)
        }
        guard let event = NSEvent(cgEvent: cgEvent) else {
            throw MobileBrowserInputReplayError.eventCreationFailed
        }
        webView.scrollWheel(with: event)
    }

    func replayKey(_ input: MobileBrowserKeyInput, in webView: WKWebView) throws {
        guard let specification = SyntheticKeyEventFactory.specification(
            key: input.key,
            modifierNames: input.modifiers
        ) else { throw MobileBrowserInputReplayError.invalidKey }
        try deliverKey(specification, characters: nil, webView: webView)
    }

    func replayText(_ input: MobileBrowserTextInput, in webView: WKWebView) async throws {
        var scriptInsertedText = ""
        for character in input.text {
            if isASCIIKeyEventCharacter(character) {
                if !scriptInsertedText.isEmpty {
                    try await insertTextWithJavaScript(scriptInsertedText, in: webView)
                    scriptInsertedText.removeAll(keepingCapacity: true)
                }
                guard let specification = SyntheticKeyEventFactory.specification(forASCIICharacter: character) else {
                    throw MobileBrowserInputReplayError.invalidKey
                }
                try deliverKey(specification, characters: specification.characters, webView: webView)
            } else {
                scriptInsertedText.append(character)
            }
        }
        if !scriptInsertedText.isEmpty {
            try await insertTextWithJavaScript(scriptInsertedText, in: webView)
        }
    }

    private func deliverMouse(
        type: NSEvent.EventType,
        button: MobileBrowserPointerButton,
        location: NSPoint,
        clickCount: Int,
        webView: WKWebView
    ) throws {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: webView.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: type == mouseDownType(for: button) ? 1 : 0
        ) else {
            throw MobileBrowserInputReplayError.eventCreationFailed
        }
        switch (button, type) {
        case (.left, .leftMouseDown): webView.mouseDown(with: event)
        case (.left, .leftMouseUp): webView.mouseUp(with: event)
        case (.right, .rightMouseDown): webView.rightMouseDown(with: event)
        case (.right, .rightMouseUp): webView.rightMouseUp(with: event)
        default: throw MobileBrowserInputReplayError.eventCreationFailed
        }
    }

    private func deliverKey(
        _ specification: SyntheticKeySpecification,
        characters: String?,
        webView: WKWebView
    ) throws {
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = SyntheticKeyEventFactory.keyEvent(
            specification: specification,
            keyDown: true,
            timestamp: timestamp,
            characters: characters
        ), let up = SyntheticKeyEventFactory.keyEvent(
            specification: specification,
            keyDown: false,
            timestamp: timestamp,
            characters: characters
        ) else {
            throw MobileBrowserInputReplayError.eventCreationFailed
        }
        if let cmuxWebView = webView as? CmuxWebView {
            cmuxWebView.forwardKeyDownToWebKit(down)
        } else {
            webView.keyDown(with: down)
        }
        webView.keyUp(with: up)
    }

    private func insertTextWithJavaScript(_ text: String, in webView: WKWebView) async throws {
        guard let literalData = try? JSONEncoder().encode(text),
              let literal = String(data: literalData, encoding: .utf8) else {
            throw MobileBrowserInputReplayError.textInsertionFailed
        }
        let script = """
        (() => {
          const el = document.activeElement;
          if (!el) return false;
          const chunk = String(\(literal));
          let proceed = true;
          try { proceed = el.dispatchEvent(new InputEvent('beforeinput', { bubbles: true, cancelable: true, inputType: 'insertText', data: chunk })); } catch (_) {}
          if (!proceed) return false;
          if ('value' in el) {
            const newValue = String(el.value || '') + chunk;
            let setter = null;
            for (let proto = Object.getPrototypeOf(el); proto; proto = Object.getPrototypeOf(proto)) {
              const descriptor = Object.getOwnPropertyDescriptor(proto, 'value');
              if (descriptor && descriptor.set) { setter = descriptor.set; break; }
            }
            if (setter) setter.call(el, newValue); else el.value = newValue;
          } else if (el.isContentEditable) {
            const selection = getSelection();
            if (selection && selection.rangeCount) {
              const range = selection.getRangeAt(0);
              range.deleteContents();
              const node = document.createTextNode(chunk);
              range.insertNode(node);
              range.setStartAfter(node);
              range.collapse(true);
              selection.removeAllRanges();
              selection.addRange(range);
            } else {
              el.append(document.createTextNode(chunk));
            }
          } else {
            return false;
          }
          try { el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: chunk })); }
          catch (_) { el.dispatchEvent(new Event('input', { bubbles: true })); }
          return true;
        })()
        """
        let inserted = try await webView.evaluateJavaScript(script, contentWorld: .page) as? Bool
        guard inserted == true else { throw MobileBrowserInputReplayError.textInsertionFailed }
    }

    private func locationInWindow(x: Double, y: Double, webView: WKWebView) throws -> NSPoint {
        guard x.isFinite, y.isFinite else { throw MobileBrowserInputReplayError.invalidCoordinates }
        let local = NSPoint(
            x: min(max(0, x), max(0, webView.bounds.width)),
            y: min(max(0, y), max(0, webView.bounds.height))
        )
        return webView.convert(local, to: nil)
    }

    private func isASCIIKeyEventCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value else { return false }
        return value == 9 || value == 10 || value == 13 || (32...126).contains(value)
    }

    private func applyScrollPhase(_ phase: MobileBrowserScrollPhase, to event: CGEvent) {
        let direct: Int64
        let momentum: Int64
        switch phase {
        case .began: (direct, momentum) = (1, 0)
        case .changed: (direct, momentum) = (2, 0)
        case .ended: (direct, momentum) = (4, 0)
        case .cancelled: (direct, momentum) = (8, 0)
        case .momentumBegan: (direct, momentum) = (0, 1)
        case .momentumChanged: (direct, momentum) = (0, 2)
        // CGMomentumScrollPhase.end is 3 (not 4): none=0, begin=1, continue=2, end=3.
        case .momentumEnded: (direct, momentum) = (0, 3)
        }
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: direct)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
    }

    private func mouseDownType(for button: MobileBrowserPointerButton) -> NSEvent.EventType {
        button == .left ? .leftMouseDown : .rightMouseDown
    }

    private func mouseUpType(for button: MobileBrowserPointerButton) -> NSEvent.EventType {
        button == .left ? .leftMouseUp : .rightMouseUp
    }
}
