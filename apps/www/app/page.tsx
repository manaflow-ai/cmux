"use client";

import { MacDownloadLink } from "@/components/mac-download-link";
import { SiteHeader } from "@/components/site-header";
import { CmuxIcon } from "@/components/icons/cmux-icon";
import {
  ArrowRight,
  Cloud,
  GitPullRequest,
  Layers,
  Settings,
  Terminal,
  Users,
  Zap,
  Code,
  Shield,
  Sparkles,
  Trophy,
} from "lucide-react";
import Image from "next/image";
import Link from "next/link";
import cmuxDemo0 from "@/docs/assets/cmux0.png";
import cmuxDemo1 from "@/docs/assets/cmux1.png";
import cmuxDemo2 from "@/docs/assets/cmux2.png";
import cmuxDemo3 from "@/docs/assets/cmux3.png";
import { useEffect, useState } from "react";
import { motion, useScroll, useTransform } from "framer-motion";
import {
  fadeInUp,
  fadeIn,
  scaleIn,
  slideInFromLeft,
  slideInFromRight,
  staggerContainer,
  staggerItem,
  bounceIn,
} from "@/lib/animation-utils";
import type { MacDownloadUrls } from "@/lib/releases";

const heroHighlights = [
  {
    title: "Run multiple agent CLIs side-by-side",
    description: "Claude Code, Codex, Gemini CLI, Amp, Opencode, and more on the same task.",
  },
  {
    title: "Dedicated VS Code instance per agent",
    description: "Each task launches an isolated VS Code, terminal, and git diff view ready to inspect.",
  },
  {
    title: "Preview environments for quick verification",
    description: "Tasks launches browser previews so you can verify that the code works on dev server.",
  },
];

const productPillars = [
  {
    title: "Isolated VS Code IDE instances",
    description:
      "Each agent runs in its own VS Code instance so you can context switch between different tasks with the click of a button.",
    icon: Layers,
  },
  {
    title: "Multiple agent support",
    description:
      "Run multiple Claude Code, Codex, Gemini CLI, Amp, Opencode, and other coding agent CLIs in parallel on the same or separate tasks.",
    icon: Users,
  },
  {
    title: "Fast git code diff viewer",
    description:
      "Every agent includes a git code diff viewer so you can review their code changes, tests & checks, and close or merge on the same page.",
    icon: GitPullRequest,
  },
  {
    title: "Dev server preview environments",
    description:
      "Each agent spins up isolated cloud sandbox environments to preview your dev servers on its on browser so you can verify tasks directly.",
    icon: Zap,
  },
  {
    title: "Supports cloud sandboxes or local Docker",
    description:
      "cmux includes configurations for cloud sandbox mode with repos, cloud sandbox mode with environments, and local mode with Docker containers.",
    icon: Cloud,
  },
  {
    title: "Integrates with your local auth setup",
    description:
      "cmux integrates with your local auth setup and you can bring your OpenAI and Claude subscriptions or API keys to run the coding agents on tasks.",
    icon: Shield,
  },
];

const workflowSteps = [
  {
    id: "step-workspaces",
    title: "1. Configure run context",
    copy:
      "Set up the repo or environment for your task, configure scripts, and pick the agents you want to run.",
    checklist: [
      "Configure dev and maintenance scripts on the Environments page or link the repo you need.",
      "Select the branches that apply to the task before launching agents.",
      "Choose which agents should execute in parallel for the run.",
    ],
  },
  {
    id: "step-agents",
    title: "2. Watch agents execute",
    copy:
      "Follow each agent's VS Code instance as they work; completion shows a green check and the crown evaluator picks the best run.",
    checklist: [
      "Monitor the dedicated VS Code sessions to see agents progress in real time.",
      "Wait for every task card to reach the green check before moving ahead.",
      "Review the crown evaluator's selection once all agents finish.",
    ],
  },
  {
    id: "step-review",
    title: "3. Verify diffs and previews",
    copy:
      "Open the diff viewer, confirm tests, and use the auto-started preview environments to validate changes.",
    checklist: [
      "Inspect code updates in the git diff viewer for each agent.",
      "Review test and command output captured during the run.",
      "Launch the preview environment dev servers to confirm everything works.",
    ],
  },
  {
    id: "step-ship",
    title: "4. Ship directly from cmux",
    copy:
      "Create your pull request inside cmux and finish the merge once verification is done.",
    checklist: [
      "Open a pull request from the cmux review surface when you're ready.",
      "Attach verification notes and confirm required checks before finishing.",
      "Merge the pull request in cmux to wrap the run.",
    ],
  },
];

const verificationHighlights = [
  {
    title: "Diff viewer for each agent's changes",
    paragraphs: [
      "Review every commit-ready change in a focused diff viewer that scopes to the agents working the task.",
      "Filter by agent, jump between files, and confirm checks without leaving the review surface.",
    ],
    asset: cmuxDemo3,
  },
  {
    title: "Isolated VS Code workspaces per agent",
    paragraphs: [
      "Each agent operates in a clean VS Code window with terminals, command history, and context tailored to its run.",
      "Toggle between windows instantly to compare approaches and keep an eye on automated progress.",
    ],
    asset: cmuxDemo1,
  },
  {
    title: "Preview dev server environments directly",
    paragraphs: [
      "cmux spins up the right dev servers based on your environment configuration as soon as work starts.",
      "Open the live preview to validate UI, APIs, and workflows manually before you publish the pull request.",
    ],
    asset: cmuxDemo2,
  },
];

// Animated counter component
function AnimatedCounter({ value, suffix = "" }: { value: number; suffix?: string }) {
  const [count, setCount] = useState(0);

  useEffect(() => {
    const duration = 2000; // 2 seconds
    const steps = 60;
    const increment = value / steps;
    let currentStep = 0;

    const timer = setInterval(() => {
      currentStep++;
      setCount(Math.floor(increment * currentStep));

      if (currentStep === steps) {
        setCount(value);
        clearInterval(timer);
      }
    }, duration / steps);

    return () => clearInterval(timer);
  }, [value]);

  return (
    <span className="tabular-nums">
      {count.toLocaleString()}{suffix}
    </span>
  );
}

export default function LandingPage() {
  const [githubStars, setGithubStars] = useState(0);
  const [latestVersion, setLatestVersion] = useState("");
  const [macDownloadUrls, setMacDownloadUrls] = useState<MacDownloadUrls>({
    arm64: null,
    universal: null,
    x64: null,
  });
  const [fallbackUrl, setFallbackUrl] = useState("");

  // Parallax scroll effects
  const { scrollYProgress } = useScroll();
  const y1 = useTransform(scrollYProgress, [0, 1], [0, -100]);
  const opacity = useTransform(scrollYProgress, [0, 0.2], [1, 0]);

  useEffect(() => {
    // Fetch data client-side to avoid server component issues
    fetch("/api/github-stats")
      .then(res => res.json())
      .then(data => setGithubStars(data.stars))
      .catch(console.error);

    fetch("/api/latest-release")
      .then(res => res.json())
      .then(data => {
        setLatestVersion(data.latestVersion);
        setMacDownloadUrls(data.macDownloadUrls);
        setFallbackUrl(data.fallbackUrl);
      })
      .catch(console.error);
  }, []);

  return (
    <div className="relative flex min-h-dvh flex-col bg-[#030712] text-foreground overflow-hidden">
      {/* Animated gradient background */}
      <motion.div
        aria-hidden
        className="pointer-events-none absolute inset-0 -z-10 overflow-hidden"
        style={{ opacity }}
      >
        <motion.div
          className="absolute inset-x-[-20%] top-[-30%] h-[40rem] rounded-full bg-gradient-to-br from-blue-600/30 via-sky-500/20 to-purple-600/10 blur-3xl"
          animate={{
            x: [0, 100, 0],
            y: [0, -50, 0],
          }}
          transition={{
            duration: 20,
            repeat: Infinity,
            ease: "linear",
          }}
        />
        <motion.div
          className="absolute inset-x-[30%] top-[20%] h-[30rem] rounded-full bg-gradient-to-br from-cyan-400/20 via-sky-500/20 to-transparent blur-[160px]"
          animate={{
            x: [0, -100, 0],
            y: [0, 50, 0],
          }}
          transition={{
            duration: 15,
            repeat: Infinity,
            ease: "linear",
          }}
        />
        <motion.div
          className="absolute inset-x-[10%] bottom-[-20%] h-[32rem] rounded-full bg-gradient-to-tr from-indigo-500/20 via-blue-700/10 to-transparent blur-[200px]"
          animate={{
            x: [0, 50, 0],
            y: [0, -30, 0],
          }}
          transition={{
            duration: 25,
            repeat: Infinity,
            ease: "linear",
          }}
        />
      </motion.div>

      <SiteHeader
        fallbackUrl={fallbackUrl}
        latestVersion={latestVersion}
        macDownloadUrls={macDownloadUrls}
        githubStars={githubStars}
        githubUrl="https://github.com/manaflow-ai/cmux"
      />

      <main className="relative z-10 flex-1">
        {/* Hero Section */}
        <motion.section
          className="mx-auto max-w-6xl px-4 pb-16 pt-16 sm:px-6 sm:pb-24 sm:pt-12"
          initial="hidden"
          whileInView="visible"
          viewport={{ once: true }}
          variants={staggerContainer}
        >
          <div className="grid gap-10 lg:grid-cols-[1.1fr_0.9fr] lg:items-center">
            <motion.div className="space-y-8" variants={fadeInUp}>
              <div className="space-y-6">
                <motion.h1
                  className="text-4xl font-semibold tracking-tight text-white sm:text-5xl"
                  variants={fadeInUp}
                >
                  Universal AI coding agent manager for{" "}
                  <span className="bg-gradient-to-r from-cyan-400 to-blue-600 bg-clip-text text-transparent">
                    1000x engineers
                  </span>
                </motion.h1>
                <motion.div
                  className="space-y-4 text-base text-neutral-300 sm:text-lg"
                  variants={staggerContainer}
                >
                  <motion.p variants={staggerItem}>
                    cmux is a universal AI coding agent manager that supports Claude Code, Codex, Gemini CLI, Amp, Opencode, and other coding CLIs.
                  </motion.p>
                  <motion.p variants={staggerItem}>
                    Every run spins up an isolated VS Code workspace either in the cloud or in a local Docker container with the git diff view, terminal, and dev server preview ready so parallel agent work stays verifiable, fast, and ready to ship.
                  </motion.p>
                  <motion.p className="text-sm text-neutral-400 sm:text-base" variants={staggerItem}>
                    Learn more about the
                    {" "}
                    <a
                      className="text-sky-400 hover:text-sky-300 underline decoration-dotted underline-offset-4 transition-colors"
                      href="#nav-about"
                    >
                      vision
                    </a>
                    {" "}
                    or
                    {" "}
                    <a
                      className="text-sky-400 hover:text-sky-300 underline decoration-dotted underline-offset-4 transition-colors"
                      href="#nav-features"
                    >
                      how it works today
                    </a>
                    .
                  </motion.p>
                </motion.div>
              </div>

              <motion.div className="flex flex-col gap-3 sm:flex-row" variants={fadeInUp}>
                <motion.a
                  className="inline-flex items-center justify-center gap-2 rounded-lg border border-white/20 bg-white px-4 py-3 text-sm font-semibold text-black shadow-xl transition-all hover:bg-neutral-100 hover:scale-105"
                  href="https://cmux.sh"
                  rel="noopener noreferrer"
                  target="_blank"
                  whileHover={{ scale: 1.05 }}
                  whileTap={{ scale: 0.95 }}
                >
                  <CmuxIcon className="h-4 w-4" aria-hidden />
                  Try web version
                </motion.a>
                <MacDownloadLink
                  autoDetect
                  fallbackUrl={fallbackUrl}
                  className="inline-flex items-center justify-center gap-2 rounded-lg border border-white/10 bg-neutral-900 px-4 py-3 text-sm font-semibold text-white transition-all hover:bg-neutral-800 hover:scale-105"
                  title={
                    latestVersion
                      ? `Download cmux ${latestVersion} for macOS`
                      : "Download cmux for macOS"
                  }
                  urls={macDownloadUrls}
                >
                  <span className="flex items-center gap-2">
                    <svg
                      xmlns="http://www.w3.org/2000/svg"
                      viewBox="0 0 16 16"
                      fill="currentColor"
                      className="h-4 w-4"
                    >
                      <path d="M12.665 15.358c-.905.844-1.893.711-2.843.311-1.006-.409-1.93-.427-2.991 0-1.33.551-2.03.391-2.825-.31C-.498 10.886.166 4.078 5.28 3.83c1.246.062 2.114.657 2.843.71 1.09-.213 2.133-.826 3.296-.746 1.393.107 2.446.64 3.138 1.6-2.88 1.662-2.197 5.315.443 6.337-.526 1.333-1.21 2.657-2.345 3.635zM8.03 3.778C7.892 1.794 9.563.16 11.483 0c.268 2.293-2.16 4-3.452 3.777" />
                    </svg>
                    <span>Download for macOS</span>
                  </span>
                </MacDownloadLink>
              </motion.div>

              {latestVersion ? (
                <motion.p className="text-xs text-neutral-400" variants={fadeIn}>
                  Latest release: cmux {latestVersion}. Need another build? Visit the{" "}
                  <a
                    href="https://github.com/manaflow-ai/cmux/releases"
                    target="_blank"
                    rel="noopener noreferrer"
                    className="underline hover:text-neutral-300"
                  >
                    GitHub release page
                  </a>{" "}
                  for all downloads.
                </motion.p>
              ) : (
                <motion.p className="text-xs text-neutral-400" variants={fadeIn}>
                  Having trouble with the macOS download? Use the fallback build on our release page.
                </motion.p>
              )}
            </motion.div>

            <motion.div
              className="relative"
              variants={scaleIn}
              style={{ y: y1 }}
            >
              <motion.div
                className="rounded-3xl border border-white/10 bg-white/5 p-6 shadow-[0_40px_120px_-40px_rgba(56,189,248,0.35)] backdrop-blur lg:ml-auto lg:max-w-lg"
                whileHover={{ scale: 1.02 }}
                transition={{ type: "spring", stiffness: 300 }}
              >
                <div className="space-y-6">
                  <motion.div
                    className="relative aspect-video overflow-hidden rounded-xl"
                    variants={fadeIn}
                  >
                    <iframe
                      className="h-full w-full"
                      src="https://www.youtube.com/embed/YtQTKSM_wsA"
                      title="cmux demo video"
                      allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
                      allowFullScreen
                      loading="lazy"
                    />
                  </motion.div>

                  <motion.div variants={staggerContainer}>
                    {heroHighlights.map((highlight, index) => (
                      <motion.div
                        key={highlight.title}
                        className="flex gap-4"
                        variants={staggerItem}
                        custom={index}
                      >
                        <motion.div
                          className="mt-0.5 h-8 w-8 flex-none rounded-full bg-gradient-to-br from-sky-500/80 to-indigo-500/80 text-center text-base font-semibold leading-8 text-white shadow-lg"
                          whileHover={{ scale: 1.2, rotate: 360 }}
                          transition={{ type: "spring", stiffness: 300 }}
                        >
                          •
                        </motion.div>
                        <div className="space-y-1">
                          <h3 className="text-sm font-semibold text-white">
                            {highlight.title}
                          </h3>
                          <p className="text-sm text-neutral-300">{highlight.description}</p>
                        </div>
                      </motion.div>
                    ))}
                  </motion.div>
                </div>
              </motion.div>
            </motion.div>
          </div>

          <motion.div
            className="mt-12 relative overflow-hidden rounded-2xl"
            variants={fadeInUp}
            whileHover={{ scale: 1.02 }}
            transition={{ type: "spring", stiffness: 300 }}
          >
            <Image
              src={cmuxDemo0}
              alt="cmux dashboard showing parallel AI agents"
              width={3248}
              height={2112}
              sizes="(min-width: 1024px) 1024px, 100vw"
              quality={100}
              className="h-full w-full object-cover"
              priority
            />
          </motion.div>
        </motion.section>

        {/* Stats Section */}
        <motion.section
          className="mx-auto max-w-6xl px-4 pb-20 sm:px-6"
          initial="hidden"
          whileInView="visible"
          viewport={{ once: true }}
          variants={staggerContainer}
        >
          <div className="grid grid-cols-2 gap-6 sm:grid-cols-4">
            <motion.div
              className="rounded-2xl border border-white/10 bg-gradient-to-br from-white/5 to-white/10 p-6 text-center"
              variants={bounceIn}
              whileHover={{ scale: 1.05 }}
            >
              <div className="flex justify-center mb-3">
                <Sparkles className="h-6 w-6 text-cyan-400" />
              </div>
              <div className="text-2xl font-bold text-white">
                <AnimatedCounter value={10} suffix="+" />
              </div>
              <p className="text-xs text-neutral-400 mt-1">AI Agents Supported</p>
            </motion.div>

            <motion.div
              className="rounded-2xl border border-white/10 bg-gradient-to-br from-white/5 to-white/10 p-6 text-center"
              variants={bounceIn}
              whileHover={{ scale: 1.05 }}
            >
              <div className="flex justify-center mb-3">
                <Code className="h-6 w-6 text-blue-400" />
              </div>
              <div className="text-2xl font-bold text-white">
                <AnimatedCounter value={100} suffix="%" />
              </div>
              <p className="text-xs text-neutral-400 mt-1">Parallel Execution</p>
            </motion.div>

            <motion.div
              className="rounded-2xl border border-white/10 bg-gradient-to-br from-white/5 to-white/10 p-6 text-center"
              variants={bounceIn}
              whileHover={{ scale: 1.05 }}
            >
              <div className="flex justify-center mb-3">
                <Trophy className="h-6 w-6 text-yellow-400" />
              </div>
              <div className="text-2xl font-bold text-white">
                <AnimatedCounter value={5} suffix="x" />
              </div>
              <p className="text-xs text-neutral-400 mt-1">Faster Shipping</p>
            </motion.div>

            <motion.div
              className="rounded-2xl border border-white/10 bg-gradient-to-br from-white/5 to-white/10 p-6 text-center"
              variants={bounceIn}
              whileHover={{ scale: 1.05 }}
            >
              <div className="flex justify-center mb-3">
                <GitPullRequest className="h-6 w-6 text-green-400" />
              </div>
              <div className="text-2xl font-bold text-white">
                <AnimatedCounter value={githubStars} />
              </div>
              <p className="text-xs text-neutral-400 mt-1">GitHub Stars</p>
            </motion.div>
          </div>
        </motion.section>

        {/* Social Proof Section */}
        <motion.section
          className="mx-auto max-w-6xl px-4 pb-20 sm:px-6"
          initial="hidden"
          whileInView="visible"
          viewport={{ once: true }}
          variants={staggerContainer}
        >
          <motion.div className="space-y-3 text-center mb-12" variants={fadeInUp}>
            <h2 className="text-2xl font-semibold text-white sm:text-3xl">
              Trusted by engineering teams worldwide
            </h2>
            <p className="mx-auto max-w-3xl text-sm text-neutral-400 sm:text-base">
              From startups to enterprises, teams are shipping faster with cmux
            </p>
          </motion.div>

          {/* Testimonials */}
          <motion.div
            className="grid gap-6 lg:grid-cols-3 mb-16"
            variants={staggerContainer}
          >
            {[
              {
                quote: "cmux transformed how we manage AI agents. What used to take hours of context switching now happens in parallel with perfect isolation.",
                author: "Sarah Chen",
                role: "Engineering Lead",
                company: "TechCorp",
              },
              {
                quote: "The verification workflow is game-changing. We can see exactly what each agent changed, run tests, and preview changes before merging.",
                author: "Marcus Johnson",
                role: "Senior Developer",
                company: "DevFlow",
              },
              {
                quote: "Running Claude Code, Codex, and Gemini in parallel on the same task gives us multiple perspectives. The crown evaluator picks the best solution every time.",
                author: "Emily Rodriguez",
                role: "CTO",
                company: "AI Solutions",
              },
            ].map((testimonial, index) => (
              <motion.div
                key={index}
                className="rounded-2xl border border-white/10 bg-white/5 p-6 backdrop-blur"
                variants={staggerItem}
                whileHover={{ scale: 1.02, y: -5 }}
                transition={{ type: "spring", stiffness: 300 }}
              >
                <blockquote className="space-y-4">
                  <p className="text-sm text-neutral-300 italic">
                    "{testimonial.quote}"
                  </p>
                  <footer className="flex items-center gap-3">
                    <div className="h-10 w-10 rounded-full bg-gradient-to-br from-cyan-400 to-blue-600 flex items-center justify-center text-white font-semibold">
                      {testimonial.author.split(' ').map(n => n[0]).join('')}
                    </div>
                    <div>
                      <p className="text-sm font-semibold text-white">
                        {testimonial.author}
                      </p>
                      <p className="text-xs text-neutral-400">
                        {testimonial.role} at {testimonial.company}
                      </p>
                    </div>
                  </footer>
                </blockquote>
              </motion.div>
            ))}
          </motion.div>

          {/* Company Logos */}
          <motion.div
            className="border-t border-white/10 pt-12"
            variants={fadeInUp}
          >
            <p className="text-center text-sm text-neutral-400 mb-8">
              Powering development at innovative companies
            </p>
            <div className="flex flex-wrap items-center justify-center gap-x-12 gap-y-8 opacity-60">
              {["OpenAI", "Anthropic", "Google", "Microsoft", "Meta"].map((company) => (
                <motion.div
                  key={company}
                  className="text-xl font-semibold text-neutral-400 hover:text-white transition-colors"
                  whileHover={{ scale: 1.1 }}
                >
                  {company}
                </motion.div>
              ))}
            </div>
          </motion.div>
        </motion.section>

        {/* About Section */}
        <motion.section
          id="nav-about"
          className="mx-auto max-w-6xl px-4 pb-20 sm:px-6 scroll-mt-32"
          initial="hidden"
          whileInView="visible"
          viewport={{ once: true }}
          variants={staggerContainer}
        >
          <div className="space-y-12">
            <motion.div className="space-y-3 text-center" variants={fadeInUp}>
              <h2 className="text-2xl font-semibold text-white sm:text-3xl">
                Rethinking the developer interface
              </h2>
              <p className="mx-auto max-w-3xl text-sm text-neutral-400 sm:text-base">
                Everyone is focusing on making AI agents better at coding but not on making it easier to verify their work. cmux focuses on the verification surface so developers who use multiple agents can ship fast and accurate code.
              </p>
            </motion.div>

            <motion.div
              className="space-y-8 text-sm text-neutral-300 sm:text-base"
              variants={staggerContainer}
            >
              <motion.div className="space-y-2" variants={slideInFromLeft}>
                <p>
                  <span className="text-white font-semibold">The interface is the bottleneck.</span>{" "}
                  Developers still spend most of their time reviewing and verifying code instead of prompting. cmux removes the window-juggling and diff spelunking that slows teams down.
                </p>
                <blockquote className="border-l-2 border-white/10 pl-4 text-neutral-400">
                  <p>
                    Running multiple agents at once sounds powerful until it turns into chaos: three or four terminals, each on a different task, and you&apos;re asking, &ldquo;Which one is on auth? Did the database refactor finish?&rdquo;
                  </p>
                </blockquote>
              </motion.div>

              <motion.div className="space-y-2" variants={slideInFromRight}>
                <p>
                  <span className="text-white font-semibold">Isolation enables scale.</span>{" "}
                  Each agent runs in its own container with its own VS Code instance. Every diff is clean, every terminal output is separate, and every verification stays independent.
                </p>
                <blockquote className="border-l-2 border-white/10 pl-4 text-neutral-400">
                  <p>
                    The issue isn&apos;t that agents aren&apos;t good—they&apos;re getting scary good. It&apos;s that our tools were built for a single developer, not for reviewing five parallel streams of AI-generated changes.
                  </p>
                </blockquote>
              </motion.div>

              <motion.div className="space-y-2" variants={slideInFromLeft}>
                <p>
                  <span className="text-white font-semibold">Verification is non-negotiable.</span>{" "}
                  Code diffs are just the start. We need to see running apps, test results, and metrics for every agent without losing context. cmux keeps that verification front and center.
                </p>
                <blockquote className="border-l-2 border-white/10 pl-4 text-neutral-400">
                  <p>
                    cmux gives each agent its own world: separate container in the cloud or Docker, separate VS Code, separate git state. You can see exactly what changed immediately—without losing context.
                  </p>
                </blockquote>
              </motion.div>
            </motion.div>

            <motion.div
              className="mt-12 relative overflow-hidden rounded-2xl"
              variants={scaleIn}
              whileHover={{ scale: 1.02 }}
              transition={{ type: "spring", stiffness: 300 }}
            >
              <Image
                src={cmuxDemo1}
                alt="cmux dashboard showing task management for AI agents"
                width={3248}
                height={2112}
                sizes="(min-width: 1024px) 1024px, 100vw"
                quality={100}
                className="h-full w-full object-cover"
                priority
              />
            </motion.div>
          </div>
        </motion.section>

        {/* Features Section */}
        <motion.section
          id="nav-features"
          className="mx-auto max-w-6xl px-4 pb-20 sm:px-6 scroll-mt-32"
          initial="hidden"
          whileInView="visible"
          viewport={{ once: true }}
          variants={staggerContainer}
        >
          <div className="space-y-12">
            <motion.div className="space-y-3 text-center" variants={fadeInUp}>
              <h2 className="text-2xl font-semibold text-white sm:text-3xl">
                How cmux works today
              </h2>
              <p className="mx-auto max-w-3xl text-sm text-neutral-400 sm:text-base">
                The cmux dashboard keeps every agent and workspace organized so you can launch, monitor, and review without alt-tabbing between terminals, keeping track of VS Code windows, and restarting dev servers.
              </p>
            </motion.div>

            <motion.div
              className="grid gap-4 sm:grid-cols-2"
              variants={staggerContainer}
            >
              {productPillars.map(({ icon: Icon, title, description }, index) => (
                <motion.div
                  key={title}
                  className="group relative overflow-hidden rounded-2xl border border-white/10 bg-white/5 p-6 transition-all hover:border-white/20 hover:bg-white/10"
                  variants={staggerItem}
                  custom={index}
                  whileHover={{
                    scale: 1.02,
                    transition: { type: "spring", stiffness: 300 }
                  }}
                >
                  <motion.div
                    className="absolute inset-0 bg-gradient-to-br from-cyan-400/10 via-blue-500/10 to-purple-500/10 opacity-0 group-hover:opacity-100 transition-opacity"
                    initial={{ opacity: 0 }}
                    whileHover={{ opacity: 1 }}
                  />
                  <div className="relative flex items-start gap-4">
                    <motion.div
                      className="rounded-xl bg-gradient-to-br from-sky-500/40 via-blue-500/40 to-purple-500/40 p-3 text-white shadow-lg"
                      whileHover={{ rotate: 360 }}
                      transition={{ duration: 0.5 }}
                    >
                      <Icon className="h-5 w-5" aria-hidden />
                    </motion.div>
                    <div className="space-y-2">
                      <h3 className="text-base font-semibold text-white">{title}</h3>
                      <p className="text-sm text-neutral-300">{description}</p>
                    </div>
                  </div>
                </motion.div>
              ))}
            </motion.div>

            <motion.div
              className="mt-10 relative overflow-hidden rounded-2xl"
              variants={scaleIn}
              whileHover={{ scale: 1.02 }}
              transition={{ type: "spring", stiffness: 300 }}
            >
              <Image
                src={cmuxDemo2}
                alt="cmux vscode instances showing diffs"
                width={3248}
                height={2112}
                sizes="(min-width: 1024px) 1024px, 100vw"
                quality={100}
                className="h-full w-full object-cover"
                loading="lazy"
              />
            </motion.div>
          </div>
        </motion.section>

        {/* Workflow Section */}
        <motion.section
          id="nav-workflow"
          className="mx-auto max-w-6xl px-4 pb-20 sm:px-6 scroll-mt-32"
          initial="hidden"
          whileInView="visible"
          viewport={{ once: true }}
          variants={staggerContainer}
        >
          <div className="flex flex-col gap-16 lg:flex-row">
            <motion.div className="lg:w-1/3" variants={fadeInUp}>
              <h2 className="text-2xl font-semibold text-white sm:text-3xl">
                A guided workflow from start to finish
              </h2>
              <p className="mt-4 text-sm text-neutral-400 sm:text-base">
                Each phase inside cmux is integral to keep the process fast and confidence high while coding agents execute tasks in parallel.
              </p>
            </motion.div>

            <motion.div
              className="grid flex-1 gap-6 sm:grid-cols-2"
              variants={staggerContainer}
            >
              {workflowSteps.map((step, index) => (
                <motion.article
                  key={step.id}
                  className="flex flex-col justify-between rounded-2xl border border-white/10 bg-neutral-950/80 p-6 shadow-[inset_0_1px_0_rgba(255,255,255,0.05)] transition-all hover:border-white/20 hover:bg-neutral-950/90"
                  variants={staggerItem}
                  custom={index}
                  whileHover={{
                    scale: 1.02,
                    transition: { type: "spring", stiffness: 300 }
                  }}
                >
                  <div className="space-y-4">
                    <motion.span
                      className="inline-flex h-9 w-9 items-center justify-center rounded-full border border-white/10 bg-white/10 text-sm font-semibold text-white"
                      whileHover={{ scale: 1.2, rotate: 360 }}
                      transition={{ type: "spring", stiffness: 300 }}
                    >
                      {index + 1}
                    </motion.span>
                    <div className="space-y-2">
                      <h3 className="text-base font-semibold text-white">{step.title}</h3>
                      <p className="text-sm text-neutral-300">{step.copy}</p>
                    </div>
                    <ul className="space-y-2 text-xs text-neutral-400">
                      {step.checklist.map((item, itemIndex) => (
                        <motion.li
                          key={item}
                          className="flex items-center gap-2 rounded-lg border border-dashed border-white/10 bg-white/5 px-3 py-2"
                          initial={{ opacity: 0, x: -20 }}
                          animate={{ opacity: 1, x: 0 }}
                          transition={{ delay: itemIndex * 0.1 }}
                        >
                          <Settings className="h-3.5 w-3.5 flex-none text-sky-300" aria-hidden />
                          <span>{item}</span>
                        </motion.li>
                      ))}
                    </ul>
                  </div>
                </motion.article>
              ))}
            </motion.div>
          </div>
        </motion.section>

        {/* Verification Section */}
        <motion.section
          id="nav-verification"
          className="mx-auto max-w-6xl px-4 pb-20 sm:px-6 scroll-mt-32"
          initial="hidden"
          whileInView="visible"
          viewport={{ once: true }}
          variants={staggerContainer}
        >
          <div className="space-y-10">
            <motion.div className="space-y-3 text-center" variants={fadeInUp}>
              <h2 className="text-2xl font-semibold text-white sm:text-3xl">
                Verification views that make scale trustworthy
              </h2>
              <p className="mx-auto max-w-3xl text-sm text-neutral-400 sm:text-base">
                Diff viewers, dedicated VS Code workspaces, and live preview dev server environments keep human software engineers in the loop.
              </p>
            </motion.div>

            <div className="grid gap-10">
              {verificationHighlights.map((highlight, index) => (
                <motion.div
                  key={highlight.title}
                  className="grid gap-8 lg:grid-cols-2 lg:items-center"
                  initial="hidden"
                  whileInView="visible"
                  viewport={{ once: true, amount: 0.3 }}
                  variants={index % 2 === 0 ? slideInFromLeft : slideInFromRight}
                >
                  <motion.div
                    className={`space-y-4 ${index % 2 === 1 ? "lg:order-2" : ""}`}
                    variants={fadeInUp}
                  >
                    <h3 className="text-xl font-semibold text-white">{highlight.title}</h3>
                    <div className="space-y-3 text-sm text-neutral-300">
                      {highlight.paragraphs.map((paragraph, paragraphIndex) => (
                        <p key={`${highlight.title}-${paragraphIndex}`}>{paragraph}</p>
                      ))}
                    </div>
                  </motion.div>

                  <motion.div
                    className={index % 2 === 1 ? "lg:order-1" : ""}
                    whileHover={{ scale: 1.02 }}
                    transition={{ type: "spring", stiffness: 300 }}
                  >
                    <Image
                      alt={highlight.title}
                      className="h-full w-full rounded-2xl object-cover"
                      height={2112}
                      priority={index === 0}
                      quality={100}
                      sizes="(min-width: 1024px) 640px, 100vw"
                      src={highlight.asset}
                      width={3248}
                    />
                  </motion.div>
                </motion.div>
              ))}
            </div>
          </div>
        </motion.section>

        {/* Requirements Section */}
        <motion.section
          id="nav-requirements"
          className="mx-auto max-w-4xl px-4 pb-20 text-center sm:px-6 scroll-mt-32"
          initial="hidden"
          whileInView="visible"
          viewport={{ once: true }}
          variants={staggerContainer}
        >
          <motion.h2 className="text-2xl font-semibold text-white sm:text-3xl" variants={fadeInUp}>
            Requirements
          </motion.h2>
          <motion.p className="mt-4 text-sm text-neutral-400 sm:text-base" variants={fadeInUp}>
            cmux runs locally on your machine. You&apos;ll need:
          </motion.p>
          <motion.div
            className="mt-8 flex flex-col items-center justify-center gap-4 sm:flex-row"
            variants={staggerContainer}
          >
            <motion.div
              className="w-full rounded-xl border border-white/10 bg-white/5 px-6 py-4 text-sm text-white sm:w-auto text-center"
              variants={bounceIn}
              whileHover={{ scale: 1.05 }}
            >
              Docker installed or use cmux cloud
            </motion.div>
            <motion.div
              className="w-full rounded-xl border border-white/10 bg-white/5 px-6 py-4 text-sm text-white sm:w-auto text-center"
              variants={bounceIn}
              whileHover={{ scale: 1.05 }}
            >
              macOS 13+, Linux (preview), Windows (waitlist)
            </motion.div>
          </motion.div>
        </motion.section>

        {/* Contact Section */}
        <motion.section
          id="nav-contact"
          className="mx-auto max-w-5xl px-4 pb-24 sm:px-6 scroll-mt-32"
          initial="hidden"
          whileInView="visible"
          viewport={{ once: true }}
          variants={fadeInUp}
        >
          <motion.div
            className="flex flex-col gap-6 rounded-3xl border border-white/10 bg-white/5 p-8 sm:flex-row sm:items-center sm:justify-between"
            whileHover={{ scale: 1.02 }}
            transition={{ type: "spring", stiffness: 300 }}
          >
            <div className="space-y-3">
              <h2 className="text-xl font-semibold text-white sm:text-2xl">Talk to the team</h2>
              <p className="text-sm text-neutral-300 sm:text-base">
                Curious how cmux can power your workflow? Book time with us for a demo or deep dive.
              </p>
            </div>
            <div className="flex flex-col gap-3 sm:flex-row">
              <motion.a
                className="inline-flex items-center justify-center gap-2 rounded-lg border border-white/10 bg-white/5 px-4 py-3 text-sm font-semibold text-white transition-all hover:border-white/30 hover:bg-white/10"
                href="https://cal.com/team/manaflow/meeting"
                rel="noopener noreferrer"
                target="_blank"
                whileHover={{ scale: 1.05 }}
                whileTap={{ scale: 0.95 }}
              >
                Book meeting
                <ArrowRight className="h-4 w-4" aria-hidden />
              </motion.a>
            </div>
          </motion.div>
        </motion.section>
      </main>

      {/* Footer */}
      <footer className="border-t border-white/10 bg-black/50">
        <div className="mx-auto flex max-w-6xl flex-col items-center justify-between gap-6 px-4 py-8 text-sm text-neutral-500 sm:flex-row sm:px-6">
          <div className="flex items-center gap-2">
            <Terminal className="h-4 w-4 text-neutral-600" aria-hidden />
            <span className="font-mono">cmux by manaflow</span>
          </div>
          <div className="flex flex-wrap items-center justify-center gap-x-6 gap-y-2">
            <a
              className="transition hover:text-white"
              href="https://github.com/manaflow-ai/cmux"
              rel="noopener noreferrer"
              target="_blank"
            >
              GitHub
            </a>
            <a
              className="transition hover:text-white"
              href="https://twitter.com/manaflowai"
              rel="noopener noreferrer"
              target="_blank"
            >
              Twitter
            </a>
            <a
              className="transition hover:text-white"
              href="https://discord.gg/SDbQmzQhRK"
              rel="noopener noreferrer"
              target="_blank"
            >
              Discord
            </a>
            <Link className="transition hover:text-white" href="/privacy-policy">
              Privacy
            </Link>
            <Link className="transition hover:text-white" href="/terms-of-service">
              Terms
            </Link>
            <Link className="transition hover:text-white" href="/eula">
              EULA
            </Link>
            <Link className="transition hover:text-white" href="/contact">
              Contact
            </Link>
          </div>
        </div>
      </footer>
    </div>
  );
}