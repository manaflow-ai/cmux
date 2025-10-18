import { ConvexQueryClient } from "@convex-dev/react-query";
import { ConvexReactClient } from "convex/react";

const convexUrl = process.env.NEXT_PUBLIC_CONVEX_URL;

if (!convexUrl) {
  throw new Error("NEXT_PUBLIC_CONVEX_URL is not configured");
}

export const convexReactClient = new ConvexReactClient(convexUrl, {
  expectAuth: true,
});

export const convexQueryClient = new ConvexQueryClient(convexReactClient, {
  expectAuth: true,
});
