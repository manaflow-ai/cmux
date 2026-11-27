
/*--------------------------------------------------------------------*/
/*--- x86/FreeBSD-specific kernel interface.     vki-x86-freebsd.h ---*/
/*--------------------------------------------------------------------*/

/*
   This file is part of Valgrind, a dynamic binary instrumentation
   framework.

   Copyright (C) 2000-2005 Julian Seward
      jseward@acm.org
   Copyright (C) 2009 Stanislav Sedov
      <stas@FreeBSD.org>
   Copyright (C) 2018-2021 Paul Floyd
      pjfloyd@wanadoo.fr

   This program is free software; you can redistribute it and/or
   modify it under the terms of the GNU General Public License as
   published by the Free Software Foundation; either version 2 of the
   License, or (at your option) any later version.

   This program is distributed in the hope that it will be useful, but
   WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program; if not, see <http://www.gnu.org/licenses/>.

   The GNU General Public License is contained in the file COPYING.
*/

#ifndef VKI_X86_FREEBSD_H
#define VKI_X86_FREEBSD_H

//----------------------------------------------------------------------
// From somewhere
//----------------------------------------------------------------------

/* PAGE_SHIFT determines the page size */
#define VKI_PAGE_SHIFT  12
#define VKI_PAGE_SIZE   (1UL << VKI_PAGE_SHIFT)
#define VKI_MAX_PAGE_SHIFT      VKI_PAGE_SHIFT
#define VKI_MAX_PAGE_SIZE       VKI_PAGE_SIZE

//----------------------------------------------------------------------
// From sys/i386/include/_limits.h and sys/sys/_sigset.h
//----------------------------------------------------------------------

#define  VKI_MINSIGSTKSZ   (512 * 4)

#define _VKI_NSIG       128
#define _VKI_NSIG_WORDS 4
#define _VKI_NSIG_BPW   ((_VKI_NSIG) / (_VKI_NSIG_WORDS))

typedef struct {
   vki_uint32_t   sig[_VKI_NSIG_WORDS];
} vki_sigset_t;


//----------------------------------------------------------------------
// From sys/i386/include/npx.h
//----------------------------------------------------------------------

struct _vki_env87 {
   long  en_cw;
   long  en_sw;
   long  en_tw;
   long  en_fip;
   unsigned short en_fcs;
   unsigned short en_opcode;
   long  en_foo;
   long  en_fos;
};

struct _vki_fpacc87 {
   unsigned char fp_bytes[10];
};

struct _vki_save87 {
   struct _vki_env87 sv_env;
   struct _vki_fpacc87  sv_ac[8];
   unsigned char  sv_pad0[4];
   unsigned char  sv_pad[64];
};

struct _vki_xmmacc {
   unsigned char  xmm_bytes[16];
};

struct _vki_envxmm {
   unsigned short en_cw;
   unsigned short en_sw;
   unsigned short en_tw;
   unsigned short en_opcode;
   unsigned int   en_fip;
   unsigned short en_fcs;
   unsigned short en_pad0;
   unsigned int   en_foo;
   unsigned short en_fos;
   unsigned short en_pad1;
   unsigned int   en_mxcsr;
   unsigned int   en_mxcsr_mask;
};

struct _vki_savexmm {
   struct _vki_envxmm   sv_env;
   struct {
      struct _vki_fpacc87 fp_acc;
      unsigned char  fp_pad[6];
   } sv_fp[8];
   struct _vki_xmmacc   sv_xmm[8];
   unsigned char  sv_pad[224];
};

struct _vki_fpstate {
   union {
      struct _vki_save87 sv_87;
      struct _vki_savexmm sv_xmm;
   };
};

struct vki_sigcontext {
   vki_sigset_t sc_mask;
   int   onstack;
   int   gs;
   int   fs;
   int   es;
   int   ds;
   int   edi;
   int   esi;
   int   ebp;
   int   isp;
   int   ebx;
   int   edx;
   int   ecx;
   int   eax;
   int   trapno;
   int   err;
   int   eip;
   int   cs;
   int   eflags;
   int   esp;
   int   ss;
   int   len;
   int   fpformat;
   int   ownedfp;
   int   spare1[1];
   struct _vki_fpstate fpstate __attribute__((aligned(16)));
   int   fsbase;
   int   gsbase;
   int   spare2[6];
};

struct vki_user_regs_struct {
   unsigned int   fs;
   unsigned int   es;
   unsigned int   ds;
   unsigned int   edi;
   unsigned int   esi;
   unsigned int   ebp;
   unsigned int   isp;
   unsigned int   ebx;
   unsigned int   edx;
   unsigned int   ecx;
   unsigned int   eax;
   unsigned int   trapno;
   unsigned int   err;
   unsigned int   eip;
   unsigned int   cs;
   unsigned int   eflags;
   unsigned int   esp;
   unsigned int   ss;
   unsigned int   gs;
};

struct vki_fpreg {
   unsigned long  fpr_env[7];
   unsigned char  fpr_acc[8][10];
   unsigned long  fpr_ex_sw;
   unsigned char  fpr_pad[64];
};

struct vki_dbreg {
   unsigned int  dr[8];
};

typedef unsigned int vki_elf_greg_t;
typedef struct _vki_fpstate vki_elf_fpregset_t;
typedef struct _vki_fpstate vki_elf_fpxregset_t;

#define VKI_AT_SYSINFO     32
#define VKI_ELF_NGREG (sizeof (struct vki_user_regs_struct) / sizeof(vki_elf_greg_t))
typedef vki_elf_greg_t vki_elf_gregset_t[VKI_ELF_NGREG];

#define VKI_FPFMT_NODEV    0x10000
#define VKI_FPFMT_387      0x10001
#define VKI_FPFMT_XMM      0x10002

#define VKI_FPOWNED_NONE   0x20000
#define VKI_FPOWNED_FPU    0x20001
#define VKI_FPOWNED_PCB    0x20002

struct vki_mcontext {
   int   onstack;
   int   gs;
   int   fs;
   int   es;
   int   ds;
   int   edi;
   int   esi;
   int   ebp;
   int   isp;
   int   ebx;
   int   edx;
   int   ecx;
   int   eax;
   int   trapno;
   int   err;
   int   eip;
   int   cs;
   int   eflags;
   int   esp;
   int   ss;

   int   len;
   int   fpformat;
   int   ownedfp;
   int   flags;
   struct _vki_fpstate fpstate __attribute__((aligned(16)));
   int   fsbase;
   int   gsbase;
   int xfpustate;
   int xfpustate_len;
   int   spare2[4];
};

struct vki_sigaction_base {
   void    (*ksa_handler)(int);
   int          sa_flags;
   vki_sigset_t sa_mask;           /* mask last for extensibility */
};
typedef  struct vki_sigaction_base  vki_sigaction_toK_t;
typedef  struct vki_sigaction_base  vki_sigaction_fromK_t;

//----------------------------------------------------------------------
// sys/vdso.h
//----------------------------------------------------------------------
#define VKI_VDSO_TIMEHANDS_MD                       \
        vki_uint32_t        th_x86_shift;           \
        vki_uint32_t        th_x86_hpet_idx;        \
        vki_uint32_t        th_res[6];

struct vki_bintime32 {
#if defined(__amd64__)
        vki_uint32_t        sec;
#else
        vki_uint64_t        sec;
#endif
        vki_uint32_t        frac[2];
};

struct vki_vdso_timehands {
        vki_uint32_t        th_algo;
        vki_uint32_t        th_gen;
        vki_uint32_t        th_scale[2];
        vki_uint32_t        th_offset_count;
        vki_uint32_t        th_counter_mask;
        struct vki_bintime32        th_offset;
        struct vki_bintime32        th_boottime;
        VKI_VDSO_TIMEHANDS_MD
};



#endif // VKI_X86_FREEBSD_H

/*--------------------------------------------------------------------*/
/*--- end                                                          ---*/
/*--------------------------------------------------------------------*/
