import { ConvexHttpClient } from "convex/browser";

export const CONVEX_URL =
  process.env.VITE_CONVEX_URL || "http://127.0.0.1:9777";
export const convex = new ConvexHttpClient(CONVEX_URL);
