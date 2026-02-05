const features = [
  {
    title: "Each agent gets its own VS Code",
    description: "Watch agents work in real-time through their own editor. Click any task to jump into that agent's session instantly.",
    icon: (
      <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9.75 17L9 20l-1 1h8l-1-1-.75-3M3 13h18M5 17h14a2 2 0 002-2V5a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z" />
      </svg>
    ),
  },
  {
    title: "Pick your favorite agents",
    description: "Claude Code, Codex CLI, Gemini CLI, Amp, Opencode—run any combination on the same task and see who writes better code.",
    icon: (
      <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M4 6a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2H6a2 2 0 01-2-2V6zM14 6a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2h-2a2 2 0 01-2-2V6zM4 16a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2H6a2 2 0 01-2-2v-2zM14 16a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2h-2a2 2 0 01-2-2v-2z" />
      </svg>
    ),
  },
  {
    title: "Review diffs before merging",
    description: "See exactly what each agent changed with a clean diff view. Check their tests, compare approaches, and merge the winner.",
    icon: (
      <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M8 7h12m0 0l-4-4m4 4l-4 4m0 6H4m0 0l4 4m-4-4l4-4" />
      </svg>
    ),
  },
  {
    title: "Preview your app live",
    description: "Every agent runs in its own sandbox with a live preview URL. Test the UI directly—no need to pull code down first.",
    icon: (
      <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M21 12a9 9 0 01-9 9m9-9a9 9 0 00-9-9m9 9H3m9 9a9 9 0 01-9-9m9 9c1.657 0 3-4.03 3-9s-1.343-9-3-9m0 18c-1.657 0-3-4.03-3-9s1.343-9 3-9m-9 9a9 9 0 019-9" />
      </svg>
    ),
  },
  {
    title: "Cloud or local—your choice",
    description: "Use cloud sandboxes for instant setup, or run locally with Docker if you prefer keeping everything on your machine.",
    icon: (
      <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M5 12h14M5 12a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v4a2 2 0 01-2 2M5 12a2 2 0 00-2 2v4a2 2 0 002 2h14a2 2 0 002-2v-4a2 2 0 00-2-2m-2-4h.01M17 16h.01" />
      </svg>
    ),
  },
  {
    title: "Bring your own API keys",
    description: "Already paying for Claude or GPT? Use your existing subscriptions. cmux works with whatever keys you have.",
    icon: (
      <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z" />
      </svg>
    ),
  },
];

function FeatureCard({ feature }: { feature: typeof features[0] }) {
  return (
    <div className="relative group p-6 rounded-xl bg-white dark:bg-neutral-900/60 border border-neutral-200 dark:border-neutral-800 hover:border-neutral-300 dark:hover:border-neutral-700 transition-colors">
      {/* Icon */}
      <div className="w-10 h-10 bg-neutral-100 dark:bg-neutral-800 rounded-lg flex items-center justify-center text-neutral-600 dark:text-neutral-400 mb-4">
        {feature.icon}
      </div>

      {/* Title */}
      <h3 className="text-lg font-medium text-neutral-900 dark:text-white mb-2">
        {feature.title}
      </h3>

      {/* Description */}
      <p className="text-sm text-neutral-600 dark:text-neutral-400 leading-relaxed">
        {feature.description}
      </p>
    </div>
  );
}

export default function Features() {
  return (
    <section id="features" className="py-32 relative bg-neutral-100/80 dark:bg-black/80">
      <div className="relative z-10 max-w-7xl mx-auto px-6">
        {/* Section header */}
        <div className="text-left mb-20">
          <h2 className="text-3xl md:text-5xl mb-6 leading-tight text-neutral-900 dark:text-white tracking-tighter" style={{ fontWeight: 420 }}>
            What you <span className="text-[#3B82F6]">get.</span>
          </h2>
          <p className="text-lg text-neutral-600 dark:text-neutral-400">
            Everything you need to run multiple AI agents and ship faster.
          </p>
        </div>

        {/* Features grid */}
        <div className="grid md:grid-cols-2 lg:grid-cols-3 gap-6">
          {features.map((feature, index) => (
            <FeatureCard key={index} feature={feature} />
          ))}
        </div>
      </div>
    </section>
  );
}
