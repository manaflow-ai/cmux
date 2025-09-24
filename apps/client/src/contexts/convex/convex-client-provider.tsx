"use client";
import { type ReactNode } from "react";
import { ConvexProvider, ConvexReactClient } from "convex/react";
import { stackClientApp } from "@/lib/stack";

const convex = new ConvexReactClient(process.env.NEXT_PUBLIC_CONVEX_URL!);
convex.setAuth(
  (stackClientApp as any).getConvexClientAuth()
);

export function ConvexClientProvider({
  children,
}: {
  children: ReactNode;
}) {
  return <ConvexProvider client={convex}>{children}</ConvexProvider>;
}
