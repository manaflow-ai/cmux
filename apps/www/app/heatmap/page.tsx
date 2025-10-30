import Link from "next/link";
import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Heatmap diff viewer for code reviews",
  description:
    "Color-coded diff viewer that highlights lines and tokens by how much human attention they need.",
};

export default function HeatmapPage() {
  return (
    <div className="flex min-h-screen flex-col items-center bg-white p-4 text-black sm:p-8">
      <div className="mx-auto mb-0 mt-8 max-w-3xl sm:mt-[70px]">
        <Link
          href="https://cmux.dev"
          className="mb-6 inline-block text-sm text-neutral-600 hover:text-black sm:mb-8"
        >
          ← Back to <span className="bg-sky-100 px-1">cmux</span>
        </Link>
        <h1 className="mb-6 text-2xl font-bold sm:mb-8 sm:text-3xl">
          A <span className="bg-yellow-200 px-1">heatmap</span> diff viewer for
          code reviews
        </h1>

        <div className="mb-6 text-sm leading-[1.6] sm:mb-8 sm:text-base">
          <p className="mb-4">
            Heatmap color-codes every diff line/token by how much{" "}
            <span className="bg-yellow-200 px-1">human attention</span> it
            probably needs. Unlike PR-review bots, we try to flag not just by
            &ldquo;is it a bug?&rdquo; but by &ldquo;is it worth a second
            look?&rdquo; (examples:{" "}
            <span className="bg-red-300 px-1">hard-coded secret</span>,{" "}
            <span className="bg-orange-300 px-1">weird crypto mode</span>,{" "}
            <span className="bg-orange-200 px-1">gnarly logic</span>
            ).
          </p>

          <p className="mb-4">
            Try it by changing any GitHub pull request url link to{" "}
            <span className="bg-yellow-300 px-1">0github.com</span>. Under the
            hood, we spin up{" "}
            <span className="bg-yellow-200 px-1">gpt-5-codex</span> for every
            diff and ask it to output a JSON data structure that we parse into a{" "}
            <span className="bg-yellow-200 px-1">colored heatmap</span>.
          </p>
        </div>

        <div className="mt-6 text-sm sm:mt-8 sm:text-base">
          <p className="mb-4">
            <span className="bg-yellow-200 px-1">Examples:</span>
          </p>
          <div className="flex flex-col gap-2">
            <a
              href="https://0github.com/tinygrad/tinygrad/pull/12999"
              target="_blank"
              rel="noopener noreferrer"
              className="break-all text-black underline"
            >
              https://
              <span className="bg-yellow-300 px-1">0github.com</span>
              /tinygrad/tinygrad/pull/12999
            </a>
            <a
              href="https://0github.com/simonw/datasette/pull/2548"
              target="_blank"
              rel="noopener noreferrer"
              className="break-all text-black underline"
            >
              https://
              <span className="bg-yellow-300 px-1">0github.com</span>
              /simonw/datasette/pull/2548
            </a>
          </div>
        </div>

        <div className="mt-6 text-sm sm:mt-8 sm:text-base">
          <p className="mb-4">
            Heatmap is <span className="bg-yellow-200 px-1">open source</span>:
          </p>
          <div className="flex flex-col gap-2">
            <a
              href="https://github.com/manaflow-ai/cmux"
              target="_blank"
              rel="noopener noreferrer"
              className="break-all text-black underline"
            >
              https://github.com/manaflow-ai/
              <span className="bg-blue-200 px-1">cmux</span>
            </a>
          </div>
        </div>
      </div>
    </div>
  );
}
