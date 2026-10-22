import AppKit
import CmuxNextCompat

extension PhoneTabView {
    func build() {
        wantsLayer = true
        picker.target = self
        picker.action = #selector(pickDevice)
        picker.autoenablesItems = false
        configure(bootButton, PhoneStrings.boot, "power", #selector(boot))
        configure(shutdownButton, PhoneStrings.shutDown, "stop.circle", #selector(shutDown))
        shutdownButton.isHidden = true
        configure(shotButton, PhoneStrings.screenshot, "camera", #selector(screenshot))
        configure(recordButton, PhoneStrings.record, "record.circle", #selector(toggleRecording))
        configure(sendButton, PhoneStrings.sendToChief, "paperplane", #selector(sendToChief))
        notesField.placeholderString = PhoneStrings.notesPlaceholder
        notesField.isHidden = true
        let bar = NSStackView(views: [picker, bootButton, shutdownButton, shotButton, recordButton, notesField, sendButton])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        screen.setAccessibilityLabel(PhoneStrings.screenLabel)
        connectScreen()
        setupView.isHidden = true
        setupView.onAction = { [weak self] action in self?.runSetup(action) }
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.lineBreakMode = .byTruncatingTail
        for view in [bar, screen, setupView, status] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            notesField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            screen.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 4),
            screen.centerXAnchor.constraint(equalTo: centerXAnchor),
            screen.widthAnchor.constraint(equalTo: widthAnchor, constant: -24),
            screen.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            setupView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            setupView.leadingAnchor.constraint(equalTo: leadingAnchor),
            setupView.trailingAnchor.constraint(equalTo: trailingAnchor),
            setupView.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    private func configure(_ button: NSButton, _ title: String, _ symbol: String, _ action: Selector) {
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
    }

    @objc private func pickDevice() {
        guard let text = picker.selectedItem?.representedObject as? String else { return }
        switch text {
        case Self.refreshItem:
            syncControls()
            run { _ in await self.recheck() }
        case Self.setupItem:
            forceSetup = true
            syncControls()
            run { _ in await self.recheck() }
        default:
            guard let id = PhoneDeviceID(text) else { return }
            select(id)
            // Picking a shut-down phone starts it: there is nothing else to do with it.
            if let device = selected, device.state == .shutdown, service.capabilities(device).contains(.boot) { boot() }
        }
    }

    @objc private func boot() {
        guard let id = deviceID else { return }
        run { try await $0.boot(id) }
    }

    @objc private func shutDown() {
        guard let id = deviceID else { return }
        run { try await $0.shutdown(id) }
    }

    /// Runs a setup screen button.
    func runSetup(_ action: PhoneSetupAction) {
        switch action {
        case .openAppStore, .openXcodeWebsite, .getAndroidStudio, .openXcode:
            if let url = action.url { NSWorkspace.shared.openInBackground(url) }
        case .downloadIOS:
            service.setup.downloadIOS()
        case .cancelDownload:
            service.setup.cancelDownload()
        case .checkAgain:
            run { _ in await self.recheck() }
        case .createIPhone:
            run { service in
                guard let made = await service.setup.createIPhone() else { return }
                try? await service.reload()
                self.select(made)
                do { try await service.boot(made) } catch { service.setup.report(error); throw error }
            }
        }
    }

    @objc private func screenshot() {
        guard let id = deviceID else { return }
        run { service in
            let file = try await service.screenshot(id)
            self.tell(PhoneErrorText(message: PhoneStrings.saved(file.path), detail: file.path))
        }
    }

    @objc private func toggleRecording() {
        guard let id = deviceID else { return }
        if service.recording != nil {
            run { service in
                let done = try await service.stopRecording(notes: self.notesField.stringValue)
                self.notesField.stringValue = ""
                self.tell(PhoneErrorText(message: PhoneStrings.saved(done.folder.path), detail: done.folder.path))
            }
        } else {
            run { try await $0.startRecording(id) }
        }
    }

    @objc private func sendToChief() {
        run { service in
            _ = try await service.sendFeedback(notes: self.notesField.stringValue)
            self.notesField.stringValue = ""
            self.tell(PhoneErrorText(message: PhoneStrings.sent, detail: ""))
        }
    }


    /// Runs one button's work; a new action clears the last one's message first.
    private func run(_ work: @escaping @MainActor (PhoneService) async throws -> Void) {
        if notice != nil { tell(nil) }
        // task-owner: one button press; it updates only this view when it ends.
        Task { [weak self] in
            guard let self else { return }
            do { try await work(self.service) } catch { self.show(error) }
        }
    }
}
