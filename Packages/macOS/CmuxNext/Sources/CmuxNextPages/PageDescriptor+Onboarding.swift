extension PageDescriptor {
    /// The onboarding tool window's page (`webviews/src/pages/onboarding/`, CmuxNextOnboarding's
    /// `OnboardingPageProvider`): cmux-page://cmux.onboarding/. It calls only its own namespace;
    /// first mouse, since the window can show without being key.
    public static let onboarding = PageDescriptor(id: "cmux.onboarding", resource: "onboarding", namespaces: ["cmux.onboarding."],
                                                  acceptsFirstMouse: true)
}
