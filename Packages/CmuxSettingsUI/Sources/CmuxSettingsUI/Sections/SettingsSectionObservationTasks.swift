extension AppSection {
    func startSettingsTask() {
        startObservingSettings()
        if languageAtAppear == nil { languageAtAppear = language.current }
        if telemetryAtAppear == nil { telemetryAtAppear = telemetry.current }
    }

    func startObservingSettings() {
        let models: [any SettingObservationStarting] = [
            language,
            appearance,
            appIcon,
            placement,
            inheritDir,
            minimalMode,
            keepWorkspaceOpen,
            firstClick,
            fileDrop,
            preferredEditor,
            openSupported,
            openMarkdown,
            markdownFontSize,
            markdownFontFamily,
            markdownMaxWidth,
            canvasPaneGap,
            canvasSnapping,
            fileEditorWordWrap,
            iMessage,
            reorder,
            dockBadge,
            menuBarOnly,
            showInMenuBar,
            paneRing,
            paneFlash,
            soundName,
            soundCommand,
            customSoundFile,
            telemetry,
            confirmQuit,
            warnCloseTab,
            warnCloseX,
            hideCloseButton,
            renameSelects,
            paletteAllSurfaces,
        ]
        models.forEach { $0.startObserving() }
    }
}

extension AutomationSection {
    func startObservingSettings() {
        let models: [any SettingObservationStarting] = [
            socketPasswordModel,
            modeModel,
            claudeCodeModel,
            claudePathModel,
            autoNamingModel,
            autoNamingAgentModel,
            autoNamingStatusModel,
            ripgrepPathModel,
            suppressSubagentModel,
            ampModel,
            cursorModel,
            geminiModel,
            kiroModel,
            kiroLevelModel,
            portBaseModel,
            portRangeModel,
        ]
        models.forEach { $0.startObserving() }
    }
}

extension BrowserSection {
    func startObservingSettings() {
        let models: [any SettingObservationStarting] = [
            disabled,
            engine,
            customName,
            customURL,
            suggestions,
            theme,
            discardEnabled,
            discardDelay,
            openTermLinks,
            interceptOpen,
            hosts,
            external,
            httpAllowlist,
            importHint,
            reactGrab,
        ]
        models.forEach { $0.startObserving() }
    }
}
