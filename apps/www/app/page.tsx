import Navbar from "@/components/landing/Navbar";
import Hero from "@/components/landing/Hero";
import Workflow from "@/components/landing/Workflow";
import Features from "@/components/landing/Features";
import Rethinking from "@/components/landing/Rethinking";
import CTA from "@/components/landing/CTA";
import Footer from "@/components/landing/Footer";
import FractalBackground from "@/components/landing/FractalBackground";

export default function Home() {
  return (
    <main className="min-h-screen relative bg-neutral-50 dark:bg-black">
      <FractalBackground />
      <div className="relative z-10">
        <Navbar />
        <Hero />
        <Workflow />
        <Features />
        <Rethinking />
        <CTA />
        <Footer />
      </div>
    </main>
  );
}
