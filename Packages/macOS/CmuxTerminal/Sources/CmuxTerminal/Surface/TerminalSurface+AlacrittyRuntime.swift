public import AppKit
internal import Carbon.HIToolbox
internal import CmuxTerminalCore
internal import Foundation
internal import GhosttyKit
#if DEBUG
internal import CMUXDebugLog
#endif

extension TerminalSurface {
    @MainActor
    func createAlacrittyRuntime(
        for view: any TerminalSurfaceNativeViewing,
        claudeShim: ClaudeCommandShim?
    ) -> Bool {
        guard alacrittyRuntime == nil else { return true }

        let launchConfiguration = resolvedRuntimeLaunchConfiguration(claudeShim: claudeShim)
        let backingSize = view.convertToBacking(
            NSRect(origin: .zero, size: view.bounds.size)
        ).size
        let widthPixels = pixelDimension(from: backingSize.width)
        let heightPixels = pixelDimension(from: backingSize.height)
        let scaleFactor = scaleFactors(for: view).layer

        do {
            let runtime = try AlacrittyTerminalRuntime.create(
                view: view.terminalRenderTargetView,
                widthPixels: max(widthPixels, 1),
                heightPixels: max(heightPixels, 1),
                scaleFactor: scaleFactor,
                fontSizePoints: launchConfiguration.fontSize,
                fontFamily: "Menlo",
                workingDirectory: launchConfiguration.workingDirectory,
                command: launchConfiguration.command,
                environment: launchConfiguration.environment,
                wake: { [weak self] in
                    self?.scheduleAlacrittyDraw()
                },
                title: { [weak self] title in
                    self?.attachedView?.terminalRuntimeTitleDidChange(title)
                },
                childExit: { [weak self] exitCode in
                    guard let self else { return }
                    self.attachedView?.terminalRuntimeChildDidExit(exitCode)
                    self.scheduleAlacrittyDraw()
                }
            )
            alacrittyRuntime = runtime
            runtimeSurfaceGeneration &+= 1
            recordRuntimeSurfaceCreation()
            if launchConfiguration.runtimeInitialInput != nil {
                nextRuntimeInitialInput = nil
            }
            additionalEnvironment.removeValue(forKey: scrollbackReplayEnvironmentKey)
            lastPixelWidth = max(widthPixels, 1)
            lastPixelHeight = max(heightPixels, 1)
            lastUncappedPixelWidth = lastPixelWidth
            lastUncappedPixelHeight = lastPixelHeight
            lastXScale = scaleFactor
            lastYScale = scaleFactor
            rendererPresentationPhase = .presented
            if let initialInput = launchConfiguration.initialInput,
               let data = initialInput.data(using: .utf8),
               !data.isEmpty {
                _ = runtime.write(data)
            }
            flushPendingAlacrittyInputIfNeeded()
            _ = runtime.draw()
            NotificationCenter.default.post(
                name: .terminalSurfaceDidBecomeReady,
                object: self,
                userInfo: [
                    "surfaceId": id,
                    "workspaceId": tabId,
                ]
            )
            onRuntimeReady?()
#if DEBUG
            logDebugEvent(
                "alacritty.surface.create.done surface=\(id.uuidString.prefix(8)) " +
                "pid=\(runtime.childPID) size=\(lastPixelWidth)x\(lastPixelHeight)"
            )
#endif
            return true
        } catch {
#if DEBUG
            logDebugEvent(
                "alacritty.surface.create.failed surface=\(id.uuidString.prefix(8)) " +
                "error=\(error.localizedDescription)"
            )
#endif
            return false
        }
    }

    @MainActor
    func teardownAlacrittyRuntime() {
        alacrittyDrawScheduled = false
        guard let runtime = alacrittyRuntime else { return }
        alacrittyRuntime = nil
        runtimeSurfaceGeneration &+= 1
        runtime.close()
    }

    @MainActor
    func scheduleAlacrittyDraw() {
        guard alacrittyRuntime != nil, !alacrittyDrawScheduled else { return }
        alacrittyDrawScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.alacrittyDrawScheduled = false
            _ = self.alacrittyRuntime?.draw()
        }
    }

    /// Draws the current Alacritty terminal frame into its hosted AppKit view.
    @MainActor
    @discardableResult
    public func drawAlacrittySurface() -> Bool {
        alacrittyRuntime?.draw() ?? false
    }

    @MainActor
    @discardableResult
    func resizeAlacrittySurface(
        widthPixels: UInt32,
        heightPixels: UInt32,
        scaleFactor: CGFloat
    ) -> Bool {
        guard let alacrittyRuntime else { return false }
        let resized = alacrittyRuntime.resize(
            widthPixels: widthPixels,
            heightPixels: heightPixels,
            scaleFactor: scaleFactor
        )
        if resized {
            lastPixelWidth = widthPixels
            lastPixelHeight = heightPixels
            lastUncappedPixelWidth = widthPixels
            lastUncappedPixelHeight = heightPixels
            lastXScale = scaleFactor
            lastYScale = scaleFactor
            _ = alacrittyRuntime.draw()
        }
        return resized
    }

    /// Sends committed text, normalizing line feeds to terminal carriage returns.
    @MainActor
    @discardableResult
    public func sendAlacrittyCommittedText(_ text: String) -> Bool {
        guard let alacrittyRuntime else { return false }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)
        var previousWasCarriageReturn = false
        for byte in text.utf8 {
            if byte == 0x0A {
                if !previousWasCarriageReturn {
                    bytes.append(0x0D)
                }
                previousWasCarriageReturn = false
            } else {
                bytes.append(byte)
                previousWasCarriageReturn = byte == 0x0D
            }
        }
        return alacrittyRuntime.write(Data(bytes))
    }

    /// Sends a hardware key event through Alacritty's terminal input encoder.
    @MainActor
    @discardableResult
    public func sendAlacrittyHardwareKey(_ event: NSEvent) -> Bool {
        guard let alacrittyRuntime else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command) else { return false }
        let modifiers = alacrittyModifiers(from: flags)

        if let key = alacrittyKey(forMacKeyCode: event.keyCode) {
            return alacrittyRuntime.sendKey(key, modifiers: modifiers)
        }

        if flags.contains(.control),
           let scalar = event.charactersIgnoringModifiers?
               .lowercased()
               .unicodeScalars
               .first {
            let value = scalar.value
            let controlByte: UInt8?
            switch value {
            case 0x40...0x5F:
                controlByte = UInt8(value & 0x1F)
            case 0x61...0x7A:
                controlByte = UInt8(value - 0x60)
            case 0x3F:
                controlByte = 0x7F
            default:
                controlByte = nil
            }
            if let controlByte {
                let bytes = flags.contains(.option)
                    ? Data([0x1B, controlByte])
                    : Data([controlByte])
                return alacrittyRuntime.write(bytes)
            }
        }

        return false
    }

    @MainActor
    func sendAlacrittyNamedKey(_ keyName: String) -> NamedKeySendResult {
        guard let event = pendingKeyEvent(for: keyName) else { return .unknownKey }
        guard let alacrittyRuntime else { return .surfaceUnavailable }
        guard !alacrittyRuntime.processExited else { return .processExited }

        if let key = alacrittyKey(forMacKeyCode: UInt16(event.keycode)) {
            let modifiers = alacrittyModifiers(fromGhostty: event.mods)
            return alacrittyRuntime.sendKey(key, modifiers: modifiers) ? .sent : .surfaceUnavailable
        }

        let normalized = keyName.lowercased()
        let parts = normalized
            .split(separator: "+")
            .flatMap { $0.split(separator: "-") }
            .map(String.init)
            .filter { !$0.isEmpty }
        guard let baseKey = parts.last,
              baseKey.count == 1,
              let scalar = baseKey.unicodeScalars.first else {
            return .unknownKey
        }
        var bytes = Array(baseKey.utf8)
        if event.mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 {
            let value = scalar.value
            guard (0x40...0x7F).contains(value) else { return .unknownKey }
            bytes = [UInt8(value & 0x1F)]
        }
        if event.mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 {
            bytes.insert(0x1B, at: 0)
        }
        return alacrittyRuntime.write(Data(bytes)) ? .sent : .surfaceUnavailable
    }

    @MainActor
    func sendAlacrittyPendingKey(_ event: PendingKeyEvent) -> Bool {
        guard let alacrittyRuntime else { return false }
        if let key = alacrittyKey(forMacKeyCode: UInt16(event.keycode)) {
            return alacrittyRuntime.sendKey(
                key,
                modifiers: alacrittyModifiers(fromGhostty: event.mods)
            )
        }

        let letterKeyCodes: [UInt32: UInt8] = [
            UInt32(kVK_ANSI_A): Character("a").asciiValue!,
            UInt32(kVK_ANSI_B): Character("b").asciiValue!,
            UInt32(kVK_ANSI_C): Character("c").asciiValue!,
            UInt32(kVK_ANSI_D): Character("d").asciiValue!,
            UInt32(kVK_ANSI_E): Character("e").asciiValue!,
            UInt32(kVK_ANSI_F): Character("f").asciiValue!,
            UInt32(kVK_ANSI_G): Character("g").asciiValue!,
            UInt32(kVK_ANSI_H): Character("h").asciiValue!,
            UInt32(kVK_ANSI_I): Character("i").asciiValue!,
            UInt32(kVK_ANSI_J): Character("j").asciiValue!,
            UInt32(kVK_ANSI_K): Character("k").asciiValue!,
            UInt32(kVK_ANSI_L): Character("l").asciiValue!,
            UInt32(kVK_ANSI_M): Character("m").asciiValue!,
            UInt32(kVK_ANSI_N): Character("n").asciiValue!,
            UInt32(kVK_ANSI_O): Character("o").asciiValue!,
            UInt32(kVK_ANSI_P): Character("p").asciiValue!,
            UInt32(kVK_ANSI_Q): Character("q").asciiValue!,
            UInt32(kVK_ANSI_R): Character("r").asciiValue!,
            UInt32(kVK_ANSI_S): Character("s").asciiValue!,
            UInt32(kVK_ANSI_T): Character("t").asciiValue!,
            UInt32(kVK_ANSI_U): Character("u").asciiValue!,
            UInt32(kVK_ANSI_V): Character("v").asciiValue!,
            UInt32(kVK_ANSI_W): Character("w").asciiValue!,
            UInt32(kVK_ANSI_X): Character("x").asciiValue!,
            UInt32(kVK_ANSI_Y): Character("y").asciiValue!,
            UInt32(kVK_ANSI_Z): Character("z").asciiValue!,
        ]
        guard var byte = letterKeyCodes[event.keycode] else { return false }
        if event.mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 {
            byte &= 0x1F
        } else if event.mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 {
            byte = Character(String(UnicodeScalar(byte)).uppercased()).asciiValue ?? byte
        }
        var bytes = [byte]
        if event.mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 {
            bytes.insert(0x1B, at: 0)
        }
        return alacrittyRuntime.write(Data(bytes))
    }

    @MainActor
    func visibleAlacrittyText() -> String? {
        alacrittyRuntime?.screenText()
    }

    @MainActor
    func alacrittyGridSize() -> (
        columns: Int,
        rows: Int,
        cellWidthPixels: Int,
        cellHeightPixels: Int
    )? {
        alacrittyRuntime?.gridSize()
    }

    /// Scrolls Alacritty's display by the requested number of history lines.
    @MainActor
    public func scrollAlacritty(lines: Int32) -> Bool {
        alacrittyRuntime?.scroll(lines: lines) ?? false
    }

    @MainActor
    private func flushPendingAlacrittyInputIfNeeded() {
        guard let alacrittyRuntime else { return }
        let queued = pendingSocketInputQueue
        pendingSocketInputQueue.removeAll(keepingCapacity: false)
        pendingSocketInputBytes = 0
        for input in queued {
            switch input {
            case .pasteText(let data), .inputText(let data):
                _ = alacrittyRuntime.write(data)
            case .processOutput:
                continue
            case .key(let event):
                if let key = alacrittyKey(forMacKeyCode: UInt16(event.keycode)) {
                    _ = alacrittyRuntime.sendKey(
                        key,
                        modifiers: alacrittyModifiers(fromGhostty: event.mods)
                    )
                }
            }
        }
    }

    private func alacrittyKey(forMacKeyCode keyCode: UInt16) -> AlacrittyTerminalKey? {
        switch Int(keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: .enter
        case kVK_Tab: .tab
        case kVK_Delete: .backspace
        case kVK_Escape: .escape
        case kVK_UpArrow: .up
        case kVK_DownArrow: .down
        case kVK_LeftArrow: .left
        case kVK_RightArrow: .right
        case kVK_Home: .home
        case kVK_End: .end
        case kVK_PageUp: .pageUp
        case kVK_PageDown: .pageDown
        case kVK_ForwardDelete: .delete
        case kVK_Help: .insert
        case kVK_F1: .f1
        case kVK_F2: .f2
        case kVK_F3: .f3
        case kVK_F4: .f4
        case kVK_F5: .f5
        case kVK_F6: .f6
        case kVK_F7: .f7
        case kVK_F8: .f8
        case kVK_F9: .f9
        case kVK_F10: .f10
        case kVK_F11: .f11
        case kVK_F12: .f12
        default: nil
        }
    }

    private func alacrittyModifiers(
        from flags: NSEvent.ModifierFlags
    ) -> AlacrittyTerminalModifiers {
        var modifiers: AlacrittyTerminalModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        return modifiers
    }

    private func alacrittyModifiers(
        fromGhostty modifiers: ghostty_input_mods_e
    ) -> AlacrittyTerminalModifiers {
        var result: AlacrittyTerminalModifiers = []
        if modifiers.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 {
            result.insert(.shift)
        }
        if modifiers.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 {
            result.insert(.control)
        }
        if modifiers.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 {
            result.insert(.option)
        }
        return result
    }
}
