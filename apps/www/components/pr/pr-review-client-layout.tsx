'use client';

import type { ReactNode } from "react";

import { ConvexClientProvider } from "@/components/providers/convex-client-provider";
import { LightModeEnforcer } from "@/components/pr/light-mode-enforcer";

export function PrReviewClientLayout({
  children,
}: {
  children: ReactNode;
}) {
  return (
    <ConvexClientProvider>
      <LightModeEnforcer>
        <div className="min-h-dvh bg-white font-sans text-neutral-900 light">
          {children}
        </div>
      </LightModeEnforcer>
    </ConvexClientProvider>
  );
}
