import AppKit

extension PhoneTabView {
    func build() {
        wantsLayer = true
        picker.target = self
        picker.action = #selector(pickDevice)
        configure(bootButton, PhoneStrings.boot, "power", #selector(boot))
        configure(shotButton, PhoneStrings.screenshot, "camera", #selector(screenshot))
        configure(recordButton, PhoneStrings.record, "record.circle", #selector(toggleRecording))
        configure(sendButton, PhoneStrings.sendToChief, "paperplane", #selector(sendToChief))
        notesField.placeholderString = PhoneStrings.notesPlaceholder
        notesField.isHidden = true
        let bar = NSStackView(views: [picker, bootButton, shotButton, recordButton, notesField, sendButton])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        screen.setAccessibilityLabel(PhoneStrings.screenLabel)
        connectScreen()
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.lineBreakMode = .byTruncatingTail
        for view in [bar, screen, status] as [NSView] {
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
        guard let text = picker.selectedItem?.representedObject as? String, let id = PhoneDeviceID(text) else { return }
        select(id)
    }

    @objc private func boot() {
        guard let id = deviceID else { return }
        status.stringValue = PhoneStrings.booting
        run { try await $0.boot(id) }
    }

    @objc private func screenshot() {
        guard let id = deviceID else { return }
        run { service in
            let file = try await service.screenshot(id)
            self.status.stringValue = PhoneStrings.saved(file.path)
        }
    }

    @objc private func toggleRecording() {
        guard let id = deviceID else { return }
        if service.recording != nil {
            run { service in
                let done = try await service.stopRecording(notes: self.notesField.stringValue)
                self.notesField.stringValue = ""
                self.status.stringValue = PhoneStrings.saved(done.folder.path)
            }
        } else {
            run { try await $0.startRecording(id) }
        }
    }

    @objc private func sendToChief() {
        run { service in
            _ = try await service.sendFeedback(notes: self.notesField.stringValue)
            self.notesField.stringValue = ""
            self.status.stringValue = PhoneStrings.sent
        }
    }


    private func run(_ work: @escaping @MainActor (PhoneService) async throws -> Void) {
        // main-hop-allow: each button's work is PhoneService's main-actor async call (simctl and adb off main); a failure shows in its resume
        Task { [weak self] in
            guard let self else { return }
            do { try await work(self.service) } catch { self.show(error) }
        }
    }
}
