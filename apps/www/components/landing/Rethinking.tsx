const points = [
  {
    title: "Rethinking the developer interface",
    description: "Everyone is focusing on making AI agents better at coding but not on making it easier to verify their work. cmux focuses on the verification surface so developers who use multiple agents can ship fast and accurate code.",
  },
  {
    title: "The interface is the bottleneck",
    description: "Developers still spend most of their time reviewing and verifying code instead of prompting. cmux removes the window-juggling and diff spelunking that slows teams down.",
  },
  {
    title: "Running multiple agents at once sounds powerful until it turns into chaos",
    description: "Three or four terminals, each on a different task, and you're asking, \"Which one is on auth? Did the database refactor finish?\"",
  },
  {
    title: "Isolation enables scale",
    description: "Each agent runs in its own container with its own VS Code instance. Every diff is clean, every terminal output is separate, and every verification stays independent.",
  },
  {
    title: "The issue isn't that agents aren't good—they're getting scary good",
    description: "It's that our tools were built for a single developer, not for reviewing five parallel streams of AI-generated changes.",
  },
  {
    title: "Verification is non-negotiable",
    description: "Code diffs are just the start. We need to see running apps, test results, and metrics for every agent without losing context. cmux keeps that verification front and center.",
  },
  {
    title: "cmux gives each agent its own world",
    description: "Separate container in the cloud or Docker, separate VS Code, separate git state. You can see exactly what changed immediately—without losing context.",
  },
];

export default function Rethinking() {
  return (
    <section className="py-32 relative bg-neutral-100/80 dark:bg-black/80">
      <div className="relative z-10 max-w-7xl mx-auto px-6">
        {/* Section header */}
        <div className="text-left mb-16">
          <h2 className="text-3xl md:text-5xl mb-6 leading-tight text-neutral-900 dark:text-white tracking-tighter" style={{ fontWeight: 420 }}>
            We are rethinking the <span className="text-[#3B82F6]">developer experience.</span>
          </h2>
        </div>

        {/* Points */}
        <div className="space-y-8">
          {points.map((point, index) => (
            <div key={index} className="flex gap-4 group">
              {/* Thin chevron indicator */}
              <div className="flex-shrink-0 pt-1">
                <svg
                  width="8"
                  height="20"
                  viewBox="0 0 12 20"
                  className="text-neutral-600 group-hover:text-neutral-400 transition-colors duration-300"
                >
                  <polygon
                    points="0,0 8,10 0,20 1.5,20 9.5,10 1.5,0"
                    fill="currentColor"
                  />
                </svg>
              </div>
              <div className="flex-1">
                <h3 className="text-xl font-medium mb-2 text-neutral-900 dark:text-white">
                  {point.title}
                </h3>
                <p className="text-neutral-600 dark:text-neutral-400 leading-relaxed max-w-3xl">
                  {point.description}
                </p>
              </div>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
