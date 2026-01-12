import { fetchGithubRepoStats } from "@/lib/fetch-github-stars";

export async function GET() {
  try {
    const stats = await fetchGithubRepoStats();
    return Response.json(stats);
  } catch (error) {
    console.error("Failed to fetch GitHub stats:", error);
    return Response.json({ stars: 0, url: "https://github.com/manaflow-ai/cmux" });
  }
}