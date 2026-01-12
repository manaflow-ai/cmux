import { Variants } from "framer-motion";

export const fadeInUp: Variants = {
  hidden: {
    opacity: 0,
    y: 20,
  },
  visible: {
    opacity: 1,
    y: 0,
    transition: {
      duration: 0.6,
      ease: "easeOut",
    },
  },
};

export const fadeIn: Variants = {
  hidden: {
    opacity: 0,
  },
  visible: {
    opacity: 1,
    transition: {
      duration: 0.6,
      ease: "easeOut",
    },
  },
};

export const scaleIn: Variants = {
  hidden: {
    opacity: 0,
    scale: 0.9,
  },
  visible: {
    opacity: 1,
    scale: 1,
    transition: {
      duration: 0.5,
      ease: "easeOut",
    },
  },
};

export const slideInFromLeft: Variants = {
  hidden: {
    opacity: 0,
    x: -50,
  },
  visible: {
    opacity: 1,
    x: 0,
    transition: {
      duration: 0.6,
      ease: "easeOut",
    },
  },
};

export const slideInFromRight: Variants = {
  hidden: {
    opacity: 0,
    x: 50,
  },
  visible: {
    opacity: 1,
    x: 0,
    transition: {
      duration: 0.6,
      ease: "easeOut",
    },
  },
};

export const staggerContainer: Variants = {
  hidden: {
    opacity: 0,
  },
  visible: {
    opacity: 1,
    transition: {
      staggerChildren: 0.1,
      delayChildren: 0.2,
    },
  },
};

export const staggerItem: Variants = {
  hidden: {
    opacity: 0,
    y: 20,
  },
  visible: {
    opacity: 1,
    y: 0,
    transition: {
      duration: 0.5,
      ease: "easeOut",
    },
  },
};

export const rotateIn: Variants = {
  hidden: {
    opacity: 0,
    rotate: -10,
    scale: 0.9,
  },
  visible: {
    opacity: 1,
    rotate: 0,
    scale: 1,
    transition: {
      duration: 0.7,
      ease: "easeOut",
    },
  },
};

export const bounceIn: Variants = {
  hidden: {
    opacity: 0,
    scale: 0.3,
  },
  visible: {
    opacity: 1,
    scale: 1,
    transition: {
      type: "spring",
      damping: 15,
      stiffness: 200,
    },
  },
};

// Enhanced animations for the landing page
export const heroTextReveal: Variants = {
  hidden: {
    opacity: 0,
    y: 30,
  },
  visible: {
    opacity: 1,
    y: 0,
    transition: {
      duration: 0.8,
      ease: [0.25, 0.1, 0.25, 1],
    },
  },
};

export const heroButtonPop: Variants = {
  hidden: {
    opacity: 0,
    scale: 0.8,
  },
  visible: {
    opacity: 1,
    scale: 1,
    transition: {
      type: "spring",
      damping: 20,
      stiffness: 300,
      delay: 0.4,
    },
  },
};

export const glowPulse: Variants = {
  hidden: {
    opacity: 0.3,
  },
  visible: {
    opacity: [0.3, 0.6, 0.3],
    transition: {
      duration: 3,
      repeat: Infinity,
      ease: "easeInOut",
    },
  },
};

export const floatingEffect: Variants = {
  hidden: {
    y: 0,
  },
  visible: {
    y: [-10, 0, -10],
    transition: {
      duration: 4,
      repeat: Infinity,
      ease: "easeInOut",
    },
  },
};

export const blurFadeIn: Variants = {
  hidden: {
    opacity: 0,
    filter: "blur(10px)",
  },
  visible: {
    opacity: 1,
    filter: "blur(0px)",
    transition: {
      duration: 0.8,
      ease: "easeOut",
    },
  },
};

export const shimmer: Variants = {
  hidden: {
    backgroundPosition: "-200% 0",
  },
  visible: {
    backgroundPosition: "200% 0",
    transition: {
      duration: 2,
      ease: "linear",
      repeat: Infinity,
      repeatDelay: 3,
    },
  },
};

export const cardFloat: Variants = {
  hidden: {
    y: 0,
    boxShadow: "0 10px 30px -10px rgba(0, 0, 0, 0.3)",
  },
  visible: {
    y: -5,
    boxShadow: "0 20px 40px -10px rgba(0, 0, 0, 0.4)",
    transition: {
      type: "spring",
      stiffness: 300,
      damping: 20,
    },
  },
};

export const textGradientShift: Variants = {
  hidden: {
    backgroundPosition: "0% 50%",
  },
  visible: {
    backgroundPosition: ["0% 50%", "100% 50%", "0% 50%"],
    transition: {
      duration: 5,
      repeat: Infinity,
      ease: "linear",
    },
  },
};